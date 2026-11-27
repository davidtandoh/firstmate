#!/usr/bin/env bash
# Durable exact-binding archive inventory for fm-omnigent.sh.
# Receipts live in <state>/omnigent-retirements/<SHA-256 of canonical key>.json.
# schema=1; key={home,task,generation,server,session}; stopped is positive
# caller-owned stop proof, never inferred from retirement or runner connectivity.
# remote_server and unnamed retain only the validated launch identity fallback.
# Each owner-only receipt is at most 8192 bytes. No transcript or credentials.
# Publication and removal use the shared record primitives.
# reconcile-retirements [--dry-run] <state> <remaining-seconds: 1-30> visits at most 20
# receipts, including invalid/locked ones, within the caller's home deadline.
# It uses exact-session reads only; unknown stops remain pending and print a
# diagnostic. A restart needs no in-memory inventory. No pending receipt expires.
# --dry-run prints the receipt and cursor paths without writes or API calls.
set -euo pipefail

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

retirement_store() { # <state>; sets RETIRE_DIR, RETIRE_HOME
  RETIRE_HOME=$(fm_backlog_canonical_existing "${FM_HOME:-${1%/*}}") || return 1
  RETIRE_DIR="$1/omnigent-retirements"
  [ ! -L "$RETIRE_DIR" ] || return 1
  (umask 077; mkdir -p "$RETIRE_DIR") || return 1
  fm_backlog_record_parent_authorized "$RETIRE_DIR/check" retirement "$1" || return 1
  [ -O "$RETIRE_DIR" ] || return 1
  local mode
  mode=$(fm_pr_file_mode "$RETIRE_DIR") || return 1
  [ $((8#$mode & 8#077)) -eq 0 ]
}

retirement_read() { # <receipt>; sets RETIRE_JSON; validates full key and filename
  local path=$1 raw keytmp digest mode LC_ALL=C
  fm_backlog_record_present "$path" retirement "$RETIRE_DIR" && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  mode=$(fm_pr_file_mode "$path") || return 1
  [ $((8#$mode & 8#077)) -eq 0 ] || return 1
  raw=$(head -c 8193 "$path" && printf '.') || return 1
  raw=${raw%.}
  [ "${#raw}" -le 8192 ] || return 1
  RETIRE_JSON=$(printf '%s' "$raw" | jq -csSe --arg home "$RETIRE_HOME" '
    select(length == 1) | .[0] |
    select(keys == ["key","remote_server","schema","stopped","unnamed"]) |
    select(.schema == 1 and (.stopped | type == "boolean")) |
    select(.key | keys == ["generation","home","server","session","task"]) |
    select(.key.home == $home) |
    select(.key.task | type == "string" and test("^[A-Za-z0-9_-]+$")) |
    select(.key.generation | type == "string" and test("^[A-Za-z0-9._-]+$")) |
    select(.key.session | type == "string" and test("^[a-f0-9]{32}$")) |
    select((.key.server | type == "string") and (.remote_server | type == "string")) |
    select(.unnamed == null or (.unnamed | type == "string"))
  ' 2>/dev/null) || return 1
  SESSION_ID=$(printf '%s' "$RETIRE_JSON" | jq -r .key.session)
  SERVER=$(printf '%s' "$RETIRE_JSON" | jq -r .key.server)
  server_valid "$SERVER" "$(printf '%s' "$RETIRE_JSON" | jq -r .remote_server)" || return 1
  keytmp=$(mktemp "$RETIRE_DIR/.key.XXXXXX") || return 1
  printf '%s' "$RETIRE_JSON" | jq -cS .key > "$keytmp"
  digest=$(fm_pr_sha256 "$keytmp") || { rm -f "$keytmp"; return 1; }
  rm -f "$keytmp"
  [ "${path##*/}" = "$digest.json" ]
}

retirement_publish() { # <receipt> <JSON>
  local staged LC_ALL=C
  [ "${#2}" -le 8191 ] || return 1
  staged=$(mktemp "$RETIRE_DIR/.receipt.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$staged" &&
    fm_backlog_atomic_transition publish "$staged" "$1" retirement "$RETIRE_DIR"; then return 0; fi
  rm -f "$staged"
  return 1
}

retirement_key() { # <task> <generation>; canonical identity shared by every writer
  jq -cnS --arg home "$RETIRE_HOME" --arg task "$1" --arg generation "$2" \
    --arg server "$SERVER" --arg session "$SESSION_ID" \
    '{home:$home,task:$task,generation:$generation,server:$server,session:$session}'
}

retirement_save() ( # <task-meta>; called under task record lock before retirement
  local meta=$1 state=${1%/*} task=${1##*/} gen keytmp digest receipt lock='' unnamed=null parent
  local wrapper started host extra
  task=${task%.meta}
  read_binding "$meta" || return 1
  if [ -z "$SESSION_ID" ]; then
    read_unnamed_session "$meta" || return 1
    [ -n "$SESSION_ID" ] || return 0
    unnamed=$(jq -cn --arg line "$(fm_meta_get "$meta" omnigent_unnamed)" '$line')
  fi
  [[ "$task" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  fm_backlog_meta_spawn_gen "$meta" "$state" || return 1
  gen=$FM_BACKLOG_META_SPAWN_GEN
  retirement_store "$state" || return 1
  keytmp=$(mktemp "$RETIRE_DIR/.key.XXXXXX") || return 1
  trap 'rm -f "$keytmp"; [ -z "${lock:-}" ] || fm_lock_release "$lock"' EXIT
  retirement_key "$task" "$gen" > "$keytmp"
  digest=$(fm_pr_sha256 "$keytmp") || return 1
  receipt="$RETIRE_DIR/$digest.json"
  fm_lock_acquire_wait_bounded "$receipt.lock" 10 || return 1
  lock="$receipt.lock"
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    retirement_read "$receipt" || return 1
    # A same-generation identity GET may finish after retirement was refused.
    # Promote only this exact receipt's fallback; retain its stop-proof field.
    if [ "$unnamed" = null ] && [ "$(printf '%s' "$RETIRE_JSON" | jq -r .unnamed)" != null ]; then
      retirement_publish "$receipt" "$(printf '%s' "$RETIRE_JSON" | jq -cS '.unnamed = null')" || return 1
    fi
    return 0
  fi
  parent=$(fm_meta_get "$meta" omnigent_remote_server)
  retirement_publish "$receipt" "$(jq -cnS --slurpfile key "$keytmp" --arg remote "$parent" --argjson unnamed "$unnamed" \
    '{schema:1,key:$key[0],stopped:false,remote_server:$remote,unnamed:$unnamed}')"
)

retirement_attempt() ( # <receipt> <caller-stop-proof: true|false>
  local receipt=$1 proof=$2 lock='' refresh_lock='' refresh_path task body='' fallback='' code='' wrapper started host extra
  trap 'rm -f -- "${body:-}" "${fallback:-}"; [ -z "$lock" ] || fm_lock_release "$lock"; [ -z "$refresh_lock" ] || fm_lock_release "$refresh_lock"' EXIT
  [ -e "$receipt" ] || return 0
  retirement_read "$receipt" || { printf 'pending Omnigent retirement %s: invalid receipt\n' "$receipt"; return 1; }
  if [ "$proof" = true ]; then
    fm_lock_acquire_wait_bounded "$receipt.lock" 10 || return 1
    lock="$receipt.lock"
    [ -e "$receipt" ] || return 0
    retirement_read "$receipt" || return 1
    if [ "$(printf '%s' "$RETIRE_JSON" | jq -r .stopped)" != true ]; then
      RETIRE_JSON=$(printf '%s' "$RETIRE_JSON" | jq -cS '.stopped = true')
      retirement_publish "$receipt" "$RETIRE_JSON" || return 1
    fi
    fm_lock_release "$lock"
    lock=''
  fi
  task=$(printf '%s' "$RETIRE_JSON" | jq -r .key.task)
  refresh_path="${RETIRE_DIR%/*}/.$task.omnigent-snapshot.json.lock"
  if [ "$proof" = true ]; then
    fm_lock_acquire_wait_bounded "$refresh_path" 10 || return 1
  else
    fm_lock_try_acquire "$refresh_path" || return 0
  fi
  refresh_lock=$refresh_path
  [ -e "$receipt" ] || return 0
  retirement_read "$receipt" || return 1
  if [ "$(printf '%s' "$RETIRE_JSON" | jq -r .stopped)" != true ]; then
    body=$(mktemp "$RETIRE_DIR/.probe.XXXXXX") || return 1
    if ! session_snapshot "$body"; then code=000; fi
    [ "$(probe_from_snapshot "$body")" = dead ] || {
      printf 'pending Omnigent retirement %s: stop unknown\n' "$receipt"
      return 0
    }
  fi
  if [ "$(printf '%s' "$RETIRE_JSON" | jq -r .unnamed)" != null ]; then
    local expected_session=$SESSION_ID expected_server=$SERVER
    fallback=$(mktemp "$RETIRE_DIR/.fallback.XXXXXX") || return 1
    printf '%s' "$RETIRE_JSON" | jq -r '"omnigent_unnamed=" + .unnamed, "omnigent_remote_server=" + .remote_server' > "$fallback"
    read_unnamed_session "$fallback" && [ "$SESSION_ID" = "$expected_session" ] && [ "$SERVER" = "$expected_server" ] || return 1
    archive_unnamed_session 0 "$fallback" || { printf 'pending Omnigent retirement %s: archive unconfirmed\n' "$receipt"; return 1; }
  else
    archive_bound_session || { printf 'pending Omnigent retirement %s: archive unconfirmed\n' "$receipt"; return 1; }
  fi
  fm_lock_acquire_wait_bounded "$receipt.lock" 10 || return 1
  lock="$receipt.lock"
  fm_backlog_atomic_transition remove "$receipt" retirement "$RETIRE_DIR"
)

retirement_archive() { # <task-meta>; foreground caller already proved native stop
  local meta=$1 state=${1%/*} keytmp digest task=${1##*/}
  retirement_store "$state" || return 1
  # Derive the exact same key as the durable pre-stop receipt.
  keytmp=$(mktemp "$RETIRE_DIR/.key.XXXXXX") || return 1
  retirement_key "${task%.meta}" "$(fm_meta_get "$meta" spawn_gen)" > "$keytmp"
  digest=$(fm_pr_sha256 "$keytmp") || { rm -f "$keytmp"; return 1; }
  rm -f "$keytmp"
  retirement_attempt "$RETIRE_DIR/$digest.json" true
}

retirement_sweep() { # <state> <remaining seconds>
  local dry=0
  if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
  [ "$#" -eq 2 ] || return 2
  local state=$1 budget=$2 receipt count=0 deadline remaining cursor='' range name
  [[ "$budget" =~ ^([1-9]|[12][0-9]|30)$ ]] || return 2
  deadline=$((SECONDS + budget))
  [ -d "$state/omnigent-retirements" ] || return 0
  retirement_store "$state" || return 1
  if [ -f "$RETIRE_DIR/.cursor" ] && [ ! -L "$RETIRE_DIR/.cursor" ]; then
    cursor=$(head -c 80 "$RETIRE_DIR/.cursor" | jq -er 'select(type == "string" and test("^[a-f0-9]{64}[.]json$"))') || cursor=''
  fi
  for range in after through; do
    for receipt in "$RETIRE_DIR/"*.json; do
      [ -f "$receipt" ] || continue
      name=${receipt##*/}
      case "$range" in
        after) [ -z "$cursor" ] || [[ "$name" > "$cursor" ]] || continue ;;
        through) [ -n "$cursor" ] && [[ ! "$name" > "$cursor" ]] || continue ;;
      esac
      remaining=$((deadline - SECONDS))
      [ "$remaining" -gt 0 ] && [ "$count" -lt 20 ] || return 0
      count=$((count + 1))
      if [ "$dry" = 1 ]; then
        printf 'would reconcile Omnigent retirement receipt %s\nwould update cursor %s\n' "$receipt" "$RETIRE_DIR/.cursor"
        continue
      fi
      retirement_publish "$RETIRE_DIR/.cursor" "\"$name\"" || return 1
      fm_run_timed "$remaining" "$SCRIPT_DIR/fm-omnigent.sh" _retry-retirement "$state" "$receipt" || true
    done
  done
}
