#!/usr/bin/env bash
# Task-bound Codex native evidence. Usage:
#   fm-codex-native.sh notify <state> <id> <spawn-gen> <brief> <notify-json>
#   fm-codex-native.sh read <state> <id> [metadata-path]
#   fm-codex-native.sh retry <state> <id>
# notify runs under the task metadata lock and rejects stale launch callbacks.
# read is side-effect free; missing, stale or unsafe evidence reads unknown.
# retry consumes one receipt per spawn generation before sending one ordinary
# resume message to the same task. Delivery uncertainty never refunds a retry.
# It never relaunches, changes a model or repeats a pipeline gate response.
# fm-codex-native.py owns native formats and bounds. --dry-run prints all possible
# output paths without writing or sending; --json is accepted on every operation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP=${1:---help}
case "$OP" in
  --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  notify|read|retry) shift ;;
  *) echo 'error: expected notify, read or retry' >&2; exit 2 ;;
esac
STATE=${1:?state directory required}
ID=${2:?task id required}
shift 2
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) exit 2 ;; esac
META="$STATE/$ID.meta"
if [ "$OP" = read ] && [ ! -f "$META" ]; then printf '{"state":"unknown"}\n'; exit 0; fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
ARGS=()
EXPECTED_GEN=
case "$OP" in
  notify)
    EXPECTED_GEN=${1:?spawn generation required}
    ARGS=(--brief "${2:?brief required}" --payload "${3:?notify JSON required}")
    shift 3 ;;
  read)
    if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then META=$1; shift; fi ;;
esac
DRY_RUN=0
for flag in "$@"; do
  case "$flag" in --dry-run) DRY_RUN=1; ARGS+=(--dry-run) ;; --json) ARGS+=(--json) ;; *) exit 2 ;; esac
done
LOCK=
cleanup() { [ -z "$LOCK" ] || fm_lock_release "$LOCK"; }
trap cleanup EXIT
if [ "$OP" != read ] && [ "$DRY_RUN" = 0 ]; then
  LOCK=$(fm_meta_lock_path "$META") || exit 1
  fm_lock_acquire_wait_bounded "$LOCK" 5 || exit 1
fi
if ! fm_backlog_meta_spawn_gen "$STATE/$ID.meta" "$STATE"; then
  if [ "$OP" = read ]; then printf '{"state":"unknown"}\n'; exit 0; fi
  printf 'error: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
GEN=$FM_BACKLOG_META_SPAWN_GEN
[ -z "$EXPECTED_GEN" ] || [ "$GEN" = "$EXPECTED_GEN" ] || { echo 'error: stale Codex notify generation' >&2; exit 1; }
PY_OP=$OP
[ "$OP" != retry ] || PY_OP=claim-retry
python3 "$SCRIPT_DIR/fm-codex-native.py" "$PY_OP" --state "$STATE" --id "$ID" --gen "$GEN" --meta "$META" "${ARGS[@]+${ARGS[@]}}"
if [ "$OP" = retry ] && [ "$DRY_RUN" = 0 ]; then
  fm_lock_release "$LOCK"
  LOCK=
  FM_STATE_OVERRIDE="$STATE" FM_SEND_EXPECTED_SPAWN_GEN="$GEN" \
    "$SCRIPT_DIR/fm-send.sh" "$ID" \
    'The canonical Codex turn failed with server_overloaded. This is the single retry for this task generation, on the same task and model. Resume from retained tool state. Read any completed drive return and reattach to an active no-mistakes run; do not resend an earlier gate response.'
fi
