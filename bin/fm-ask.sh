#!/usr/bin/env bash
# fm-ask.sh - structured, deduplicated records of what firstmate asks the captain.
#
# Every time the main firstmate session asks the captain for a decision or an
# approval, or reports a blocker that needs the captain, it records the ask here
# BEFORE sending the reply. An external notifier (for example a webhook relay)
# then reads one record per ask instead of parsing chat prose, so it can send
# exactly one event per new ask, never bundle asks, and never re-send a closed
# one. This script owns the record format below; it sends nothing itself.
#
# Usage:
#   fm-ask.sh open --task <task-id> --kind decision|approval|blocker \
#     --question <text> [--option <LABEL>=<text>]... \
#     [--recommend <LABEL> --reason <text>] [--link <https-url>]... [--key <ask-id>]
#   fm-ask.sh close (<ask-id> | --task <task-id>) --answered|--withdrawn
#
# RECORD FORMAT (schema 1). One JSON object per ask, one file per ask at
# `$FM_HOME/state/captain-asks/<ask_id>.json`, written atomically (temp file in
# the same directory, fsync, rename) with mode 600 in a mode-700 directory:
#   schema          1
#   ask_id          lowercase slug `<task_id>-<kind>-<n>`, or the caller's --key
#   task_id         the task the ask belongs to, as given (e.g. GB-hook-1031)
#   kind            decision | approval | blocker
#   question        one plain-text sentence
#   options         list of {"label": "A", "text": "<one plain line>"}; may be empty
#   recommendation  {"label": "A", "reason": "<one plain line>"} or null
#   links           list of full https URLs
#   asked_at        RFC 3339 UTC, set once when the ask is first recorded
#   state           open | answered | withdrawn
#   closed_at       RFC 3339 UTC, present only when state is not open
# Readers ignore any file that does not end in `.json` (temporary files are
# dot-prefixed and end in `.tmp`).
#
# VALIDATION. Every text field must be one line of plain text: line breaks,
# control characters and markdown (emphasis pairs, `~~`, backticks, `](`, and
# a leading `#`, `>`, `- `, `* `, or `+ `) are refused rather than stripped, so
# what a notifier sends is exactly what was recorded. Option labels are 1-16
# letters, digits or hyphens, unique per ask, and a recommendation must name an
# option label when options exist. Links must be https URLs with a host and no
# whitespace.
#
# IDENTITY AND IDEMPOTENCY. Without --key, `open` reuses the record whose
# task, kind, question, options, recommendation and links are identical, so a
# reminder that re-records the same ask keeps its ask_id and asked_at; a new
# ask gets the next free <n> for its `<task_id>-<kind>` prefix (the task id is
# lowercased and any other character outside [a-z0-9-] becomes `-`). With
# --key, the key (a lowercase slug of at most 128 characters) is the ask_id:
# re-opening it with identical content is a no-op and with different content is
# refused. A closed ask is never reopened: `open` that matches one exits 3 and
# names it, and asking the same thing again needs a new --key. `open` prints
# `opened: <ask_id>` or `unchanged: <ask_id>`.
#
# CLOSING. `close <ask_id>` marks one ask answered or withdrawn; `close --task`
# closes every open ask of that task. Closing an already-closed ask with the
# same outcome is a no-op; a different outcome is refused. `close` prints
# `<state>: <ask_id>` for each ask it changed or confirmed. bin/fm-captain-hold.sh
# `answer` (and its keyed `answers` intake) runs `close --task <task> --answered`
# whenever it records the captain's answer for a task, so asks recorded under
# the held task's id close with the answer.
#
# All mutations hold an exclusive lock on `captain-asks/.lock`. A record that
# cannot be parsed stops the command with its path rather than being skipped.
# Exit codes: 0 success, 1 failure, 2 usage, 3 the matching ask is closed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ASK_DIR="$STATE/captain-asks"

usage() {
  sed -n '/^# Usage:/,/^# RECORD FORMAT/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  open|close) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "fm-ask: python3 is required" >&2; exit 1; }

exec python3 - "$ASK_DIR" "$@" <<'PY'
import datetime, fcntl, json, os, re, sys
from urllib.parse import urlsplit

ask_dir = sys.argv[1]
argv = sys.argv[2:]
cmd, args = argv[0], argv[1:]

KINDS = ("decision", "approval", "blocker")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,127}\Z")
TASK = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,15}\Z")
MARKDOWN_INLINE = ("**", "__", "~~", "`", "](")
MARKDOWN_EMPHASIS = re.compile(r"\*(?=\S)(?:[^*]*?\S)?\*|(?<!\w)_(?=\S)(?:.*?\S)?_(?!\w)")
MARKDOWN_LEAD = re.compile(r"(?:#|>|[-*+]\s)")


class Usage(Exception):
    pass


def die(msg, code=1):
    print(f"fm-ask: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def plain(label, value):
    if value != value.strip() or not value:
        die(f"{label} must be non-empty with no leading or trailing whitespace")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        die(f"{label} must be one plain line with no line breaks or control characters")
    for frag in MARKDOWN_INLINE:
        if frag in value:
            die(f"{label} contains markdown ({frag}); use plain text")
    if MARKDOWN_EMPHASIS.search(value):
        die(f"{label} contains markdown emphasis; use plain text")
    if MARKDOWN_LEAD.match(value):
        die(f"{label} starts with markdown; use plain text")
    return value


def https_link(value):
    parts = urlsplit(value)
    if parts.scheme != "https" or not parts.hostname or re.search(r"\s", value) \
            or len(value) > 2048 or any(ord(c) < 32 for c in value):
        die(f"link must be a full https URL: {value!r}")
    return value


def take(i, flag):
    if i + 1 >= len(args):
        raise Usage(f"{flag} needs a value")
    return args[i + 1]


def lock():
    os.makedirs(ask_dir, mode=0o700, exist_ok=True)
    os.chmod(ask_dir, 0o700)
    fd = os.open(os.path.join(ask_dir, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def load_all():
    records = []
    if not os.path.isdir(ask_dir):
        return records
    for name in sorted(os.listdir(ask_dir)):
        if not name.endswith(".json") or name.startswith("."):
            continue
        path = os.path.join(ask_dir, name)
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            if not isinstance(rec, dict) or rec.get("schema") != 1 \
                    or rec.get("ask_id") != name[:-5]:
                raise ValueError("not a schema 1 record matching its file name")
        except (OSError, ValueError) as exc:
            die(f"unreadable captain ask record {path}: {exc}")
        records.append(rec)
    return records


def write(rec):
    path = os.path.join(ask_dir, rec["ask_id"] + ".json")
    tmp = os.path.join(ask_dir, f".{rec['ask_id']}.json.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    dfd = os.open(ask_dir, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def content(rec):
    return (rec["task_id"], rec["kind"], rec["question"], rec["options"],
            rec["recommendation"], rec["links"])


def cmd_open():
    task = kind = question = key = rec_label = reason = None
    options, links = [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--task": task = take(i, a)
        elif a == "--kind": kind = take(i, a)
        elif a == "--question": question = take(i, a)
        elif a == "--option":
            v = take(i, a)
            if "=" not in v:
                raise Usage("--option takes LABEL=TEXT")
            options.append(tuple(v.split("=", 1)))
        elif a == "--recommend": rec_label = take(i, a)
        elif a == "--reason": reason = take(i, a)
        elif a == "--link": links.append(take(i, a))
        elif a == "--key": key = take(i, a)
        else:
            raise Usage(f"unknown argument {a!r}")
        i += 2
    if task is None or kind is None or question is None:
        raise Usage("open needs --task, --kind and --question")
    if not TASK.match(task):
        die(f"invalid task id {task!r}")
    if kind not in KINDS:
        die(f"kind must be one of {', '.join(KINDS)}, not {kind!r}")
    question = plain("question", question)
    opts, seen = [], set()
    for label, text in options:
        if not LABEL.match(label):
            die(f"invalid option label {label!r}")
        if label in seen:
            die(f"duplicate option label {label!r}")
        seen.add(label)
        opts.append({"label": label, "text": plain(f"option {label}", text)})
    if (rec_label is None) != (reason is None):
        raise Usage("--recommend and --reason go together")
    recommendation = None
    if rec_label is not None:
        if not LABEL.match(rec_label):
            die(f"invalid recommendation label {rec_label!r}")
        if opts and rec_label not in seen:
            die(f"recommendation {rec_label!r} names no option")
        recommendation = {"label": rec_label, "reason": plain("recommendation reason", reason)}
    links = [https_link(u) for u in links]
    if key is not None:
        if not SLUG.match(key):
            die(f"--key must be a lowercase slug of at most 128 characters: {key!r}")

    rec = {"schema": 1, "ask_id": None, "task_id": task, "kind": kind,
           "question": question, "options": opts, "recommendation": recommendation,
           "links": links, "asked_at": None, "state": "open"}
    lock()
    existing = load_all()
    match = None
    if key is not None:
        match = next((r for r in existing if r["ask_id"] == key), None)
        if match is not None and content(match) != content(rec):
            die(f"ask {key} is already recorded with different content")
    else:
        match = next((r for r in existing if content(r) == content(rec)), None)
    if match is not None:
        if match.get("state") != "open":
            die(f"ask {match['ask_id']} is already {match.get('state')}; "
                "a closed ask is never reopened - use a new --key to ask again", 3)
        print(f"unchanged: {match['ask_id']}")
        return
    if key is None:
        prefix = re.sub(r"[^a-z0-9-]", "-", task.lower()) + "-" + kind + "-"
        used = [int(r["ask_id"][len(prefix):]) for r in existing
                if r["ask_id"].startswith(prefix) and r["ask_id"][len(prefix):].isdigit()]
        key = f"{prefix}{max(used, default=0) + 1}"
        if not SLUG.match(key):
            die(f"task id {task!r} yields an ask id longer than 128 characters; pass --key")
    rec["ask_id"] = key
    rec["asked_at"] = now()
    write(rec)
    print(f"opened: {key}")


def cmd_close():
    target = task = outcome = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--answered", "--withdrawn"):
            if outcome is not None:
                raise Usage("give exactly one of --answered or --withdrawn")
            outcome = a[2:]
            i += 1
        elif a == "--task":
            task = take(i, a)
            i += 2
        elif not a.startswith("-") and target is None:
            target = a
            i += 1
        else:
            raise Usage(f"unknown argument {a!r}")
    if outcome is None or (target is None) == (task is None):
        raise Usage("close needs one <ask_id> or --task, and --answered or --withdrawn")
    if target is not None and not SLUG.match(target):
        die(f"invalid ask id {target!r}")
    lock()
    records = load_all()
    if target is not None:
        chosen = [r for r in records if r["ask_id"] == target]
        if not chosen:
            die(f"no captain ask {target}")
    else:
        chosen = [r for r in records if r.get("task_id") == task and r.get("state") == "open"]
    stamp = now()
    for r in chosen:
        if r.get("state") == "open":
            r["state"] = outcome
            r["closed_at"] = stamp
            write(r)
        elif r.get("state") != outcome:
            die(f"ask {r['ask_id']} is already {r.get('state')}")
        print(f"{outcome}: {r['ask_id']}")


try:
    {"open": cmd_open, "close": cmd_close}[cmd]()
except Usage as exc:
    die(f"{exc}; see fm-ask.sh --help", 2)
PY
