#!/usr/bin/env bash
# Declare scratch, record confirmed completion, and report/prune task data.
# Usage: fm-task-retention.sh declare ID [--scratch GLOB] [--worktree-cache NAME]
#        fm-task-retention.sh complete ID [--artifact RELPATH] [--worktree PATH --lease-released]
#        fm-task-retention.sh confirm-merge ID --merged-pr URL
#        fm-task-retention.sh confirm-local ID --project PATH --branch NAME --head SHA
#        fm-task-retention.sh start ID [--dry-run] [--json]
#        fm-task-retention.sh report [--json] [--prune] [--periodic] [--dry-run]
# FM_HOME and FM_{DATA,STATE,CONFIG}_OVERRIDE select this home's roots.
# Declaration is exclusive; edit scratch.json deliberately before completion
# to extend it. Completion seals its digest; later edits block eligibility.
# Relative, segment-based globs support *, ?, [] and ** beneath data/ID only.
# No declaration means no deletion. Worktree caches are always report-only.
# Complete is called by teardown only after endpoint closure, lease release,
# and backlog transition. confirm-merge is called by the confirmed merge owner.
# Prune requires config/task-retention=prune AND --prune. Default is report.
# --periodic publishes state/task-retention-report.json at most weekly, for the
# existing watcher. --dry-run lists intended paths and writes/deletes nothing.
# tick is the watcher's detached, singleton scheduling entrypoint; a successful
# weekly publication or failure appends one existing durable check wake.
# .task-retention-attempt records the last attempt under the singleton lock;
# retries back off for one hour across watcher restarts and drained wake queues.
# Schema, resource bounds, validation and descriptor-safe traversal are owned
# by fm-task-retention.py. Internal backlog/archived modes reuse backlog owners.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
if [ "${1:-}" = locked-prune ]; then
  [ "$#" -eq 2 ] || { echo 'error: locked-prune requires one task ID' >&2; exit 2; }
  # The shared runner owns process-group cleanup, including owner death. A
  # timed-out report must never leave a pruning grandchild behind its lock.
  fm_exec_timed 110 1 bash "$SCRIPT_DIR/fm-task-retention.sh" _locked-prune "$2"
fi
if [ "${1:-}" = tick ]; then
  if [ "$#" -ne 1 ]; then
    if [ "$#" -eq 2 ] && [ "$2" = --dry-run ]; then
      fm_exec_timed 120 1 python3 "$SCRIPT_DIR/fm-task-retention.py" report --periodic --prune --dry-run
    fi
    echo 'error: tick accepts only --dry-run' >&2
    exit 2
  fi
  DATA="${FM_DATA_OVERRIDE:-${FM_HOME:?FM_HOME required}/data}"
  # A home with no task-data root has nothing to retain. In particular, do
  # not manufacture a failure wake in a state-only supervision home.
  [ -e "$DATA" ] || [ -L "$DATA" ] || exit 0
  STATE="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME required}/state}"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock="$STATE/.task-retention.lock"
  fm_lock_try_acquire "$lock" || exit 0
  trap 'fm_lock_release "$lock"' EXIT
  attempt="$STATE/.task-retention-attempt"
  if [ -e "$attempt" ] || [ -L "$attempt" ]; then
    [ ! -L "$attempt" ] && [ -d "$attempt" ] || {
      echo 'error: unsafe task retention attempt marker' >&2
      exit 1
    }
    [ "$(fm_path_age "$attempt")" -ge 3600 ] || exit 0
    rmdir "$attempt"
  fi
  mkdir "$attempt"
  if output=$(fm_exec_timed 120 1 python3 "$SCRIPT_DIR/fm-task-retention.py" report --periodic --prune); then
    [ -z "$output" ] || fm_wake_append check task-retention \
      "check: task-retention report ready: $STATE/task-retention-report.json"
  else
    fm_wake_append check task-retention \
      'check: task-retention report failed; run bin/fm-task-retention.sh report for the bounded diagnostic'
    exit 1
  fi
  exit
fi
if [ "${1:-}" = _locked-prune ]; then
  STATE="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME required}/state}"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$STATE/$2.meta")
  fm_lock_acquire_wait_bounded "$lock" 2
  trap 'fm_lock_release "$lock"' EXIT
  python3 "$SCRIPT_DIR/fm-task-retention.py" report --prune --locked-task "$2" --json
  exit
fi
if [ "${1:-}" = held ] || [ "${1:-}" = backlog ] || [ "${1:-}" = archived ]; then
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  if [ "$1" = archived ]; then
    fm_exec_timed 8 1 bash "$SCRIPT_DIR/fm-captain-hold.sh" archived "$2" --full
  fi
  if [ "$1" = held ]; then
    FM_TASKS_AXI_TIMEOUT=10 fm_backlog_row_list "${FM_DATA_OVERRIDE:-${FM_HOME:?FM_HOME required}/data}" \
      --state held --limit 201 | awk -F, '
        /^count:/ || /^tasks\[/ { print; next }
        /^  [A-Za-z0-9_][A-Za-z0-9._-]*,/ { sub(/^  /, "", $1); print $1 }
      '
    exit
  fi
  FM_TASKS_AXI_TIMEOUT=10 fm_backlog_row_list "${FM_DATA_OVERRIDE:-${FM_HOME:?FM_HOME required}/data}" \
    --limit 2001 --fields body,hold_kind,hold_reason,links
  exit
fi
fm_exec_timed 120 1 python3 "$SCRIPT_DIR/fm-task-retention.py" "$@"
