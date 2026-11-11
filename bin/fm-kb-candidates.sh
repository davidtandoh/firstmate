#!/usr/bin/env bash
# fm-kb-candidates.sh - record what happened to each knowledge-base candidate a
# worker's report lists, and verify that every one is accounted for.
#
# The capture policy is owned by .agents/skills/ship-landing/SKILL.md: before
# cleanup firstmate files each candidate in data/<id>/report.md's
# `## Knowledge-base candidates` section as a proposal, or declines it with a
# reason. This script supplies the durable record of that outcome and the
# completion gate bin/fm-teardown.sh runs, so a skipped filing step refuses
# cleanup instead of silently losing the candidates.
#
# Usage:
#   fm-kb-candidates.sh list <task-id>
#   fm-kb-candidates.sh filed <task-id> <n> <proposal-id-or-file>
#   fm-kb-candidates.sh declined <task-id> <n> <reason>
#   fm-kb-candidates.sh verify <task-id>
#
# Candidates are numbered from 1 in report order. Each top-level list item
# (`-`, `*`, `+`, or `1.`/`1)`) is one candidate; continuation lines and
# nested items belong to that candidate, including when list indentation varies.
# A non-empty section with no such item is one candidate. A section that is
# empty, or whose only text starts with the word `none`, lists no candidates,
# and a task with no report or no such section has nothing to account for.
#
# `filed` records the proposal id the home's capture flow returned, or the
# one-word file a home without that flow routed the candidate to.
# `declined` records a one-line reason, including the destination when the
# candidate was handed to another home.
# A later record for the same candidate replaces the earlier one.
# Each record is written to the task's metadata (state/<id>.meta, the gate's
# source) as kb_candidate_<n>=<sha256> <outcome> <value>, where sha256 hashes
# the full candidate text with list markers removed and whitespace collapsed.
# A changed candidate needs a fresh outcome.
# When this home's backlog transitions apply, each outcome is appended as one
# line to the backlog task note; a manually edited backlog prints that line
# for the operator to add by hand.
#
# `verify` is read-only and is what bin/fm-teardown.sh calls without --force.
# It exits 0 when every listed candidate has a matching record, or 1, naming
# each unaccounted candidate and the commands that resolve it.
# `list` prints each candidate's number, outcome or `unrecorded`, and first line.
#
# Exit codes: 0 success; 1 refusal or verification failure; 2 invalid usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '12,16p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

candidates() {
  [ -f "$1" ] || return 0
  awk -v full="${2:-0}" '
    function normalized(text) {
      gsub(/[[:space:]]+/, " ", text)
      sub(/^ /, "", text)
      sub(/ $/, "", text)
      return text
    }
    function flush() {
      if (!in_section) return
      if (count == 0 && first_text != "") {
        probe = tolower(first_text)
        sub(/^[*_`[:space:]]+/, "", probe)
        if (probe ~ /^none([^a-z0-9]|$)/ && lines == 1) return
        print (full ? normalized(section_text) : substr(first_text, 1, 160))
        return
      }
      for (i = 1; i <= count; i++)
        print (full ? normalized(items[i]) : substr(heads[i], 1, 160))
    }
    /^##?[[:space:]]/ {
      if (in_section) { flush(); in_section = 0; done = 1 }
      if (!done && tolower($0) ~ /^##[[:space:]]+knowledge-base candidates[[:space:]]*$/) in_section = 1
      next
    }
    in_section {
      if ($0 ~ /^[[:space:]]*$/) next
      lines++
      if (first_text == "") first_text = $0
      section_text = section_text " " $0
      text = $0
      if (text ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/) {
        match(text, /^[[:space:]]*/)
        indent = RLENGTH
        if (count == 0 || indent < content_indent) {
          match(text, /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/)
          content_indent = RLENGTH
          text = substr(text, content_indent + 1)
          heads[++count] = text
          items[count] = text
          next
        }
      }
      if (count > 0) items[count] = items[count] " " text
    }
    END { flush() }
  ' "$1"
}

require_task() {  # <task-id>
  fm_task_id_path_safe "$1" || { usage >&2; exit 2; }
  META="$STATE/$1.meta"
  REPORT="$DATA/$1/report.md"
  [ -f "$META" ] || fail "task record is absent: $META"
  CANDIDATE_TEXT=$(candidates "$REPORT" 1)
}

meta_value() {  # <key>; the last value recorded in the task metadata
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

candidate_count() {
  if [ -z "$CANDIDATE_TEXT" ]; then
    printf '0\n'
  else
    printf '%s\n' "$CANDIDATE_TEXT" | awk 'END { print NR }'
  fi
}

outcome_of() {  # <n>
  meta_value "kb_candidate_$1" | cut -d' ' -f2-
}

candidate_hash() {
  printf '%s\n' "$CANDIDATE_TEXT" | sed -n "${1}p" | fm_pr_sha256 /dev/stdin
}

command_list() {
  local id=$1 n=0 text outcome extracted
  require_task "$id"
  extracted=$(candidates "$REPORT")
  if [ -z "$extracted" ]; then
    printf 'no knowledge-base candidates listed for %s\n' "$id"
    return 0
  fi
  while IFS= read -r text; do
    n=$((n + 1))
    outcome=$(outcome_of "$n")
    printf '%s\t%s\t%s\n' "$n" "${outcome:-unrecorded}" "$text"
  done <<EOF
$extracted
EOF
}

command_verify() {
  local id=$1 total n stored hash missing='' changed=''
  require_task "$id"
  total=$(candidate_count)
  n=1
  while [ "$n" -le "$total" ]; do
    case "$(outcome_of "$n")" in
      filed\ ?*|declined\ ?*)
        stored=$(meta_value "kb_candidate_$n")
        hash=$(candidate_hash "$n") || fail "could not hash candidate $n"
        if [ "${stored%% *}" != "$hash" ]; then
          changed="${changed}${changed:+ }$n"
        fi
        ;;
      *) missing="${missing}${missing:+ }$n" ;;
    esac
    n=$((n + 1))
  done
  if [ -n "$missing$changed" ]; then
    if [ -n "$missing" ]; then
      printf 'unrecorded knowledge-base candidates for %s: %s of %s\n' "$id" "$missing" "$total" >&2
    fi
    if [ -n "$changed" ]; then
      printf 'changed knowledge-base candidates for %s: %s of %s; record a fresh outcome\n' "$id" "$changed" "$total" >&2
    fi
    printf 'See them with bin/fm-kb-candidates.sh list %s, file each as a proposal and record it with bin/fm-kb-candidates.sh filed %s <n> <proposal-id-or-file>, or record bin/fm-kb-candidates.sh declined %s <n> "<reason>".\n' \
      "$id" "$id" "$id" >&2
    exit 1
  fi
  printf 'verified: %s knowledge-base candidates accounted for (%s)\n' "$id" "$total"
}

command_record() {  # <outcome> <task-id> <n> <value>
  local outcome=$1 id=$2 n=$3 value=$4 total kind line record lock rc hash
  require_task "$id"
  case "$n" in ''|0*|*[!0-9]*) fail "candidate number must be a positive integer: $n" ;; esac
  case "$value" in
    *[[:cntrl:]]*) fail "the $outcome value must be one line without control characters" ;;
  esac
  [ -n "${value//[[:space:]]/}" ] || fail "the $outcome value is empty"
  total=$(candidate_count)
  [ "$n" -le "$total" ] || fail "report for $id lists $total knowledge-base candidate(s); there is no candidate $n"
  case "$outcome" in
    filed)
      case "$value" in *[[:space:]]*) fail "the filed reference must be one word: $value" ;; esac
      line="Knowledge-base candidate $n: filed as $value"
      ;;
    declined)
      line="Knowledge-base candidate $n: declined - $value"
      ;;
  esac
  hash=$(candidate_hash "$n") || fail "could not hash candidate $n"
  record="$hash $outcome $value"

  kind=$(meta_value kind)
  [ -n "$kind" ] || kind=ship
  rc=0
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$kind" || rc=$?
  case "$rc" in
    0)
      fm_backlog_append_body_line "$DATA" "$id" "$line" \
        || fail "could not record the outcome on the task note: $FM_BACKLOG_TRANSITION_ERROR"
      ;;
    1) printf 'note: the backlog is not updated automatically here (%s); add this line to the task note: %s\n' \
         "$FM_BACKLOG_TRANSITION_SKIP" "$line" ;;
    *) fail "cannot reach the backlog: $FM_BACKLOG_TRANSITION_ERROR" ;;
  esac

  lock=$(fm_meta_lock_path "$META") || fail "could not resolve the task metadata lock"
  fm_lock_acquire_wait "$lock" || fail "could not lock the task metadata"
  if [ ! -f "$META" ]; then
    fm_lock_release "$lock"
    fail "task record disappeared while recording: $META"
  fi
  printf 'kb_candidate_%s=%s\n' "$n" "$record" >> "$META" || {
    fm_lock_release "$lock"
    fail "could not write the task record: $META"
  }
  fm_lock_release "$lock"
  printf 'recorded: %s\n' "$line"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  list|verify)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    "command_$1" "$2"
    ;;
  filed|declined)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    command_record "$1" "$2" "$3" "$4"
    ;;
  *) usage >&2; exit 2 ;;
esac
