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
#   unavailable - pushed owner copy is unusable; callers defer with exit 75.

FM_UPGRADE_WINDOW_DEFER_EXIT=75

# shellcheck source=bin/fm-timeout-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-timeout-lib.sh"

fm_upgrade_window_dir() {
  local root=${AGENT_KIT_OBSERVATION_DIR:-$HOME/.agents/state/observation}
  case "$root" in "~"/*) root=$HOME/${root#"~/"} ;; esac
  printf '%s/serve\n' "$root"
}

# Pushed-copy contract: one <=64 KiB JSON envelope per https server origin in
# the receiving home's state directory. schema_version=1, server (exact origin),
# published_at (owner epoch seconds), window (Kit object, or null for absent).
# A copy is usable for 600 seconds, with no future timestamps accepted.
# The owner watcher publishes changes on its next poll and refreshes every 60s.
# fm-on.sh supplies the existing authenticated transport; there is no reverse
# SSH connection. Failed peers retry on the same bounded refresh cadence.
fm_upgrade_window_copy_path() {
  printf '%s/upgrade-window-%s.json\n' "${FM_HOME:-${BASH_SOURCE[0]%/bin/*}}/state" "${1#https://}"
}

fm_upgrade_window_unpack() {
  jq -cers --arg server "$1" --argjson now "$2" '
    select(length == 1) | .[0] |
    select(type == "object" and .schema_version == 1 and .server == $server
      and (.published_at | type == "number" and floor == .)
      and .published_at <= $now and .published_at >= ($now - 600)
      and has("window") and (.window == null or (.window | type == "object"))) | .window | tojson'
}

# A remote registry binding names this home's server only when this home is
# itself a local owner (no inherited remote server). Registry parsing remains
# owned by fm-secondmate-registry-lib.sh.
fm_upgrade_window_local_owner() {
  [ -z "${FM_OMNIGENT_SERVER:-}" ] || return 1
  local reg="${FM_DATA_OVERRIDE:-${FM_HOME:-${BASH_SOURCE[0]%/bin/*}}/data}/secondmates.md" line
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || return 1
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] &&
      [ "$SECONDMATE_REGISTRY_OMNIGENT_SERVER" = "${1%/}" ]; then return 0; fi
  done < "$reg"
  return 1
}

# fm_upgrade_window_publish <state-dir> [now-epoch]
# Called by the existing watcher. Work per destination is bounded to 8 seconds;
# failures retry at the 60s cadence, changes bypass that cadence immediately.
fm_upgrade_window_publish() (
  local state=$1 now=${2:-$(date +%s)} reg line window payload marker previous stamp signature server id file
  [ -z "${FM_OMNIGENT_SERVER:-}" ] || return 0
  reg="${FM_DATA_OVERRIDE:-${FM_HOME:-${state%/state}}/data}/secondmates.md"
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-secondmate-registry-lib.sh"
  file="$(fm_upgrade_window_dir)/upgrade-window.json"
  window=null
  if [ -e "$file" ] || [ -L "$file" ]; then
    window='{}'
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      window=$(head -c 65537 "$file" 2>/dev/null) || window='{}'
      window=$(printf '%s' "$window" | jq -ces 'select(length == 1 and (.[0] | type == "object")) | .[0]') || window='{}'
    fi
  fi
  if [ "$(printf '%s' "$window" | wc -c)" -gt 64000 ]; then window='{}'; fi
  # Leave room for the envelope within the 64 KiB transport limit.
  # Invalid owner data must invalidate the destination copy, never bless it.
  signature=$window
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || return 1
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || continue
    server=$SECONDMATE_REGISTRY_OMNIGENT_SERVER id=$SECONDMATE_REGISTRY_ID
    [ -n "$server" ] || continue
    marker="$state/.upgrade-window-push-$id"
    previous=$(head -c 65537 "$marker" 2>/dev/null) || previous=
    stamp=${previous%%$'\n'*}
    case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
    if [ "$((now - stamp))" -lt 60 ] && [ "${previous#*$'\n'}" = "$server $signature" ]; then continue; fi
    # Record attempts too, so a failed peer does not stall every watcher poll.
    printf '%s\n%s %s\n' "$now" "$server" "$signature" > "$marker"
    payload=$(jq -cn --arg server "$server" --argjson now "$now" --arg window "$window" '
      {schema_version:1,server:$server,published_at:$now,window:($window|try fromjson catch {})}') || continue
    printf '%s\n' "$payload" | fm_run_timed 8 "${BASH_SOURCE[0]%/*}/fm-on.sh" --stdin "$id" \
      fm-upgrade-window.sh receive "$server" >/dev/null 2>&1 || true
  done < "$reg"
)

# fm_upgrade_window_read [now-epoch] [server]
# Sets FM_UPGRADE_WINDOW_STATE (active|closed|absent|invalid|unavailable) and,
# for active or closed, FM_UPGRADE_WINDOW_JOB, _PHASE, _OUTCOME (outcome or "expired"),
# _EXPIRES, and _SESSIONS (one interrupted session id per line).
fm_upgrade_window_read() {
  local now=${1:-$(date +%s)} server=${2:-} file fields content remote=0
  file="$(fm_upgrade_window_dir)/upgrade-window.json"
  FM_UPGRADE_WINDOW_FILE=$file
  FM_UPGRADE_WINDOW_JOB='' FM_UPGRADE_WINDOW_PHASE='' FM_UPGRADE_WINDOW_OUTCOME=''
  FM_UPGRADE_WINDOW_EXPIRES='' FM_UPGRADE_WINDOW_SESSIONS=''
  if [ -n "$server" ]; then
    server=${server%/}
    if ! [[ "$server" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]]; then
      FM_UPGRADE_WINDOW_STATE=unavailable
      return 0
    fi
    if ! fm_upgrade_window_local_owner "$server"; then
      remote=1
      file=$(fm_upgrade_window_copy_path "$server")
      FM_UPGRADE_WINDOW_FILE=$file
      if [ ! -f "$file" ] || [ -L "$file" ]; then
        FM_UPGRADE_WINDOW_STATE=unavailable
        return 0
      fi
      content=$(head -c 65537 "$file" 2>/dev/null) || content=
      if [ "$(printf '%s' "$content" | wc -c)" -gt 65536 ]; then content=; fi
      content=$(printf '%s' "$content" | fm_upgrade_window_unpack "$server" "$now") || {
        FM_UPGRADE_WINDOW_STATE=unavailable
        return 0
      }
      if [ "$content" = null ]; then FM_UPGRADE_WINDOW_STATE=absent; return 0; fi
    else
      # This home owns the registered binding's server. Read the owner's
      # local file, without requiring SSH to its public Tailscale Serve name.
      fm_upgrade_window_read "$now" ""
      return 0
    fi
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
    if [ "$remote" = 1 ]; then FM_UPGRADE_WINDOW_STATE=unavailable; else FM_UPGRADE_WINDOW_STATE=invalid; fi
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
  fm_upgrade_window_publish "$state"
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
