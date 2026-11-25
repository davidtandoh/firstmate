#!/usr/bin/env bash
# fm-upgrade-window-lib.sh - Firstmate's reader of the Agent Kit's Omnigent
# upgrade pause window. Sourced, never executed.
#
# The Kit's upgrade worker owns the window and its schema
# (personal-agent-kit ADR-0030; integrations/tooling/agent-kit-observation/
# upgrade.md "Firstmate pause window"). It writes
#   ${AGENT_KIT_OBSERVATION_DIR:-~/.agents/state/observation}/serve/upgrade-window.json
# before draining Omnigent and closes it with the outcome. This file owns only
# Firstmate's reading of it:
#   active  - phase pausing or switching, and expires_at still in the future.
#             docs/omnigent.md "Upgrade pause window" owns operator behavior;
#             each caller owns its deferral status and retry contract.
#   closed  - phase resumed, or an open phase whose expires_at has passed.
#   absent  - no window file.
#   invalid - unreadable or outside the schema; it warns and is treated as no
#             window, because a window with no readable expiry has no bound.
#   unavailable - remote owner could not be read; callers defer with exit 75.

FM_UPGRADE_WINDOW_DEFER_EXIT=75

# shellcheck source=bin/fm-timeout-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-timeout-lib.sh"

fm_upgrade_window_dir() {
  local root=${AGENT_KIT_OBSERVATION_DIR:-$HOME/.agents/state/observation}
  case "$root" in "~"/*) root=$HOME/${root#"~/"} ;; esac
  printf '%s/serve\n' "$root"
}

# fm_upgrade_window_read [now-epoch] [server]
# Sets FM_UPGRADE_WINDOW_STATE (active|closed|absent|invalid|unavailable) and,
# for active or closed, FM_UPGRADE_WINDOW_JOB, _PHASE, _OUTCOME (outcome or "expired"),
# _EXPIRES, and _SESSIONS (one interrupted session id per line).
fm_upgrade_window_read() {
  local now=${1:-$(date +%s)} server=${2:-} file fields content host
  file="$(fm_upgrade_window_dir)/upgrade-window.json"
  FM_UPGRADE_WINDOW_FILE=$file
  FM_UPGRADE_WINDOW_JOB= FM_UPGRADE_WINDOW_PHASE= FM_UPGRADE_WINDOW_OUTCOME=
  FM_UPGRADE_WINDOW_EXPIRES= FM_UPGRADE_WINDOW_SESSIONS=
  if [ -n "$server" ]; then
    host=${server#https://}
    host=${host%/}
    host=${host%%:*}
    if ! [[ "$server" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]]; then
      FM_UPGRADE_WINDOW_STATE=unavailable
      return 0
    fi
    content=$(fm_run_timed 8 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -- "$host" \
      'f="${AGENT_KIT_OBSERVATION_DIR:-$HOME/.agents/state/observation}/serve/upgrade-window.json"; if [ ! -e "$f" ] && [ ! -L "$f" ]; then printf absent; else head -c 65537 "$f"; fi' 2>/dev/null) || {
      FM_UPGRADE_WINDOW_STATE=unavailable
      return 0
    }
    if [ "$content" = absent ]; then FM_UPGRADE_WINDOW_STATE=absent; return 0; fi
  else
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      FM_UPGRADE_WINDOW_STATE=absent
      return 0
    fi
    content=$(head -c 65537 "$file" 2>/dev/null) || { FM_UPGRADE_WINDOW_STATE=invalid; return 0; }
  fi
  fields=$(printf '%s' "$content" | jq -er '
    def clean: type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not);
    select(type == "object" and .schema_version == "1" and (.job | clean)
      and (.phase == "pausing" or .phase == "switching" or .phase == "resumed")
      and (.expires_at | type == "number")
      and ((.outcome == null) or (.outcome | clean))
      and ((.interrupted_sessions // []) | type == "array" and length <= 256 and all(.[]; clean)))
    | [.job, .phase, (.outcome // ""), (.expires_at | floor | tostring)] + (.interrupted_sessions // [])
    | join("\n")' 2>/dev/null) || {
    FM_UPGRADE_WINDOW_STATE=invalid
    return 0
  }
  FM_UPGRADE_WINDOW_JOB=$(printf '%s\n' "$fields" | sed -n 1p)
  FM_UPGRADE_WINDOW_PHASE=$(printf '%s\n' "$fields" | sed -n 2p)
  FM_UPGRADE_WINDOW_OUTCOME=$(printf '%s\n' "$fields" | sed -n 3p)
  FM_UPGRADE_WINDOW_EXPIRES=$(printf '%s\n' "$fields" | sed -n 4p)
  FM_UPGRADE_WINDOW_SESSIONS=$(printf '%s\n' "$fields" | sed -n '5,$p')
  if [ "$FM_UPGRADE_WINDOW_PHASE" = resumed ]; then
    FM_UPGRADE_WINDOW_STATE=closed
  elif [ "$FM_UPGRADE_WINDOW_EXPIRES" -gt "$now" ]; then
    FM_UPGRADE_WINDOW_STATE=active
  else
    FM_UPGRADE_WINDOW_STATE=closed
    FM_UPGRADE_WINDOW_OUTCOME=expired
  fi
}

# fm_upgrade_window_gate <what> [state-dir] [server]
# 0 when no window is active (an invalid file warns on stderr); an active
# window or unavailable remote read prints a deferral and returns
# FM_UPGRADE_WINDOW_DEFER_EXIT. Only an active window records its job as
# deferred in this home when <state-dir> is given.
# An omitted server inherits FM_OMNIGENT_SERVER; an empty server reads locally.
fm_upgrade_window_gate() {
  fm_upgrade_window_read "$(date +%s)" "${3-${FM_OMNIGENT_SERVER:-}}"
  case "$FM_UPGRADE_WINDOW_STATE" in
    active)
      [ -z "${2:-}" ] || fm_upgrade_window_note_deferred "$2"
      echo "deferred: an Omnigent upgrade (job $FM_UPGRADE_WINDOW_JOB, phase $FM_UPGRADE_WINDOW_PHASE) has paused new Omnigent work until it resumes or $(date -u -r "$FM_UPGRADE_WINDOW_EXPIRES" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$FM_UPGRADE_WINDOW_EXPIRES" +%Y-%m-%dT%H:%MZ); $1 was not started and nothing changed - retry after the window closes" >&2
      return "$FM_UPGRADE_WINDOW_DEFER_EXIT"
      ;;
    unavailable)
      echo "deferred: cannot read the Omnigent server owner's upgrade window; $1 was not started" >&2
      return "$FM_UPGRADE_WINDOW_DEFER_EXIT"
      ;;
    invalid)
      echo "warning: ignoring unreadable Omnigent upgrade window $FM_UPGRADE_WINDOW_FILE (outside the Agent Kit schema)" >&2
      ;;
  esac
  return 0
}

# fm_upgrade_window_note_deferred <state-dir> - remember that this home held
# work for the active job, so its close raises a wake. Best-effort.
fm_upgrade_window_note_deferred() {
  [ "$(cat "$1/.upgrade-window-deferred" 2>/dev/null)" = "$FM_UPGRADE_WINDOW_JOB" ] ||
    printf '%s\n' "$FM_UPGRADE_WINDOW_JOB" > "$1/.upgrade-window-deferred" 2>/dev/null || true
}

fm_upgrade_window_tasks() {
  local state=$1 meta session verdict backend target id
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    session=$(sed -n 's/^omnigent_session=//p' "$meta" | tail -n 1)
    [ "$(sed -n 's/^omnigent=//p' "$meta" | tail -n 1)" = on ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ ! -f "$state/$id.review-park" ] || continue
    [ -z "$(sed -n 's/^remote_host=//p' "$meta" | tail -n 1)" ] || continue
    if [ -z "$session" ]; then
      # shellcheck source=bin/fm-backend.sh
      . "${BASH_SOURCE[0]%/*}/fm-backend.sh"
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      [ -n "$target" ] || continue
      verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || verdict=unknown
      case "$verdict" in dead|missing) printf '%s\n' "$id" ;; esac
    elif printf '%s\n' "$FM_UPGRADE_WINDOW_SESSIONS" | grep -qxF -- "$session"; then
      basename "$meta" .meta
    else
      verdict=$("${BASH_SOURCE[0]%/*}/fm-omnigent.sh" probe "$meta") || verdict=unknown
      [ "$verdict" != dead ] || basename "$meta" .meta
    fi
  done
}

# fm_upgrade_window_supervise <state-dir>
# One watcher poll; runs in the caller's shell so FM_UPGRADE_WINDOW_STATE stays
# set. When this home deferred work for a job, closing, removing, or invalidating
# its window produces a check reason. A closed readable window also produces a
# reason for eligible local recovery tasks from fm_upgrade_window_tasks.
# FM_UPGRADE_WINDOW_REASON is set to one check reason; the caller queues it and
# then runs fm_upgrade_window_commit so it is raised once per job. Otherwise
# FM_UPGRADE_WINDOW_REASON stays empty.
fm_upgrade_window_supervise() {
  local state=$1 deferred_job='' tasks
  FM_UPGRADE_WINDOW_REASON=
  fm_upgrade_window_read "$(date +%s)" "${FM_OMNIGENT_SERVER:-}"
  [ ! -f "$state/.upgrade-window-deferred" ] || deferred_job=$(cat "$state/.upgrade-window-deferred")
  case "$FM_UPGRADE_WINDOW_STATE" in
    active)
      return 0
      ;;
    closed) ;;
    unavailable) return 0 ;;
    *)
      [ -n "$deferred_job" ] || return 0
      FM_UPGRADE_WINDOW_JOB=$deferred_job
      FM_UPGRADE_WINDOW_REASON="check: omnigent-upgrade $deferred_job closed (window $FM_UPGRADE_WINDOW_STATE); Omnigent dispatch and steering resume"
      return 0
      ;;
  esac
  [ "$(cat "$state/.upgrade-window-surfaced" 2>/dev/null)" != "$FM_UPGRADE_WINDOW_JOB" ] || return 0
  tasks=$(fm_upgrade_window_tasks "$state" | tr '\n' ' ')
  tasks=${tasks% }
  if [ -z "$tasks" ] && [ "$deferred_job" != "$FM_UPGRADE_WINDOW_JOB" ]; then
    fm_upgrade_window_commit "$state"
    return 0
  fi
  FM_UPGRADE_WINDOW_REASON="check: omnigent-upgrade $FM_UPGRADE_WINDOW_JOB closed (${FM_UPGRADE_WINDOW_OUTCOME:-resumed}); Omnigent dispatch and steering resume"
  [ -z "$tasks" ] || FM_UPGRADE_WINDOW_REASON="$FM_UPGRADE_WINDOW_REASON; relaunch interrupted or stopped workers with bin/fm-control.sh <task> relaunch: $tasks"
}

# fm_upgrade_window_commit <state-dir> - record the closed job as surfaced.
fm_upgrade_window_commit() {
  rm -f "$1/.upgrade-window-deferred"
  printf '%s\n' "$FM_UPGRADE_WINDOW_JOB" > "$1/.upgrade-window-surfaced"
}
