#!/usr/bin/env bash
# Close the processes a finished task launched, and only those.
#
# Sourced by bin/fm-teardown.sh after the recorded endpoint is closed and the
# cwd-based reap (its header's Fix 2) has run. That reap only reaches processes
# whose working directory is inside the task's own copy or temp root; a helper
# or browser the worker started elsewhere survives it. This step closes those
# survivors by identity, never by process name.
#
# Ownership (fm_task_proc_classify) is decided per process from its command line
# and launch environment, as `ps -E` (macOS) or `ps e` (Linux) prints them:
#   own      the environment carries this home's exact FM_TASK_INBOX for the
#            task (bin/fm-spawn.sh exports that absolute, home-scoped path into
#            every launch, and children inherit it), or the process is a browser
#            whose --user-data-dir is under the task's per-job profile root
#            (the task temp root, where briefs place the per-job profile).
#   unclear  some trace of the task without that proof: the bare FM_TASK_ID
#            (another home can reuse a task id), a mention of the task's copy or
#            temp root, or an env-tagged process that looks like a protected
#            application (the captain's own desktop apps and browsers, Omnigent,
#            Hermes, mlflow, Tailscale, Screen Sharing, the remote job worker,
#            or the 6767 server). Unclear processes are listed, never signalled.
#   (none)   everything else is not printed at all.
#
# fm_task_proc_close signals `own` processes with SIGTERM once, waits a short
# grace period, and reports what remains. It never escalates to SIGKILL and
# never fails the caller: cleanup reports survivors for a human to judge.
# It never signals itself or any ancestor.
#
# Inputs to both functions are passed as variables so tests can drive the
# classifier with fake listings and never touch real processes:
#   FM_TASK_PROC_INBOX    absolute steering inbox path of the task (required)
#   FM_TASK_PROC_ID       task id
#   FM_TASK_PROC_PROFILE  per-job profile root (the task temp root)
#   FM_TASK_PROC_PATHS    newline-separated task-owned paths (copy, temp root)

. "$(dirname "${BASH_SOURCE[0]}")/fm-backend-hometag-lib.sh"

fm_task_proc_browser_session() {
  local tag
  tag=$(FM_HOME=$1 FM_ROOT=$1 fm_backend_hometag) || return 1
  printf 'fm-%s-%s\n' "$tag" "$2"
}

fm_task_proc_executable() {
  ps -p "$1" -o comm= 2>/dev/null
}

# Listing format on stdout: one process per line, "<pid> <command and env>".
fm_task_proc_listing() {
  if [ "$(uname -s)" = Darwin ]; then
    ps -axww -E -o pid=,command= 2>/dev/null
  else
    ps axeww -o pid=,args= 2>/dev/null
  fi
}

# Lowercase-glob patterns of applications cleanup must never close, even when
# they carry the task's environment tag. Matching one only downgrades to unclear.
fm_task_proc_protected() {  # <text>
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *chatgpt*|*codex.app*|*skycomputeruseservice*|*"brave browser"*|*"google chrome.app"*|\
    *safari*|*grok*|*omnigent*|*hermes*|*mlflow*|*tailscale*|*"screen sharing"*|\
    *screensharing*|*fm-remote-job-worker*|*6767*) return 0 ;;
  esac
  return 1
}

# Print this shell's pid and each ancestor pid, one per line, so callers can
# exclude them.
fm_task_proc_ancestors() {
  local pid=$$ next n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
    printf '%s\n' "$pid"
    next=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ "$next" != "$pid" ] || break
    pid=$next
    n=$((n + 1))
  done
}

# Read a listing on stdin; print "own<TAB><pid><TAB><reason><TAB><text>" or
# "unclear<TAB><pid><TAB><reason><TAB><text>" for each process with a trace of
# the task. Pids named in FM_TASK_PROC_EXCLUDE (newline-separated) are skipped.
fm_task_proc_classify() {
  local inbox=${FM_TASK_PROC_INBOX:-} id=${FM_TASK_PROC_ID:-} profile=${FM_TASK_PROC_PROFILE:-}
  local line pid text padded reason p alt executable
  [ -n "$inbox" ] || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    pid=${line%% *}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    text=${line#"$pid"}
    text=${text# }
    if [ -n "${FM_TASK_PROC_EXCLUDE:-}" ] && printf '%s\n' "$FM_TASK_PROC_EXCLUDE" | grep -Fxq "$pid"; then
      continue
    fi
    text=$(printf '%s' "$text" | tr '\t' ' ')
    padded=" $text "
    reason=
    if [ -n "$profile" ]; then
      for p in "$profile" "/private$profile"; do
        case "$padded" in
          *" --user-data-dir=$p "*) reason=browser-profile ;;
        esac
      done
    fi
    if [ -n "$reason" ]; then
      printf 'own\t%s\t%s\t%s\n' "$pid" "$reason" "$text"
      continue
    fi
    case "$padded" in
      *" FM_TASK_INBOX=$inbox "*)
        if ! executable=$(fm_task_proc_executable "$pid") || [ -z "$executable" ] || fm_task_proc_protected "$executable"; then
          printf 'unclear\t%s\t%s\t%s\n' "$pid" protected-app "$text"
        else
          printf 'own\t%s\t%s\t%s\n' "$pid" task-env "$text"
        fi
        continue
        ;;
    esac
    if [ -n "$id" ]; then
      case "$padded" in
        *" FM_TASK_ID=$id "*)
          printf 'unclear\t%s\t%s\t%s\n' "$pid" task-id-without-inbox "$text"
          continue
          ;;
      esac
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      for alt in "$p" "/private$p"; do
        case "$padded" in
          *"$alt "*|*"$alt/"*) reason=path-mention ;;
        esac
      done
    done <<EOF
${FM_TASK_PROC_PATHS:-}
EOF
    [ -z "$reason" ] || printf 'unclear\t%s\t%s\t%s\n' "$pid" "$reason" "$text"
  done
}

fm_task_proc_short() {  # <text> -> first 160 characters, for reports
  printf '%.160s' "$1"
}

# Close the task's own processes. <label> names the task in report lines.
# Reports go to stderr. Always returns 0.
fm_task_proc_close() {  # <label>
  local label=$1 listing classes own_pids remaining pid kind reason text identity current waited=0
  FM_TASK_PROC_EXCLUDE=$(fm_task_proc_ancestors)
  if ! listing=$(fm_task_proc_listing) || [ -z "$listing" ]; then
    echo "warning: could not list processes to close $label's leftover helpers; nothing was closed" >&2
    return 0
  fi
  classes=$(printf '%s\n' "$listing" | FM_TASK_PROC_EXCLUDE=$FM_TASK_PROC_EXCLUDE fm_task_proc_classify) || return 0
  own_pids=$(printf '%s\n' "$classes" | awk -F '\t' '$1 == "own" { print $2 }')
  while IFS="$(printf '\t')" read -r kind pid reason text; do
    [ "$kind" = unclear ] || continue
    echo "teardown: left process $pid running for $label (ownership unclear: $reason): $(fm_task_proc_short "$text")" >&2
  done <<EOF
$classes
EOF
  [ -n "$own_pids" ] || return 0
  echo "teardown: closing $label's leftover process(es): $(printf '%s' "$own_pids" | tr '\n' ' ')" >&2
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(task_process_identity "$pid") || continue
    listing=$(fm_task_proc_listing) || continue
    current=$(printf '%s\n' "$listing" | FM_TASK_PROC_EXCLUDE=$FM_TASK_PROC_EXCLUDE fm_task_proc_classify) || continue
    printf '%s\n' "$current" | awk -F '\t' -v pid="$pid" '$1 == "own" && $2 == pid { found=1 } END { exit !found }' || continue
    task_process_identity_matches "$pid" "$identity" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<EOF
$own_pids
EOF
  remaining=$own_pids
  while [ -n "$remaining" ] && [ "$waited" -lt "${FM_TASK_PROC_GRACE:-3}" ]; do
    sleep 1
    waited=$((waited + 1))
    listing=$(fm_task_proc_listing) || break
    classes=$(printf '%s\n' "$listing" | FM_TASK_PROC_EXCLUDE=$FM_TASK_PROC_EXCLUDE fm_task_proc_classify) || break
    remaining=$(printf '%s\n' "$classes" | awk -F '\t' '$1 == "own" { print $2 }' | grep -Fx -f <(printf '%s\n' "$own_pids") || true)
  done
  [ -z "$remaining" ] && return 0
  echo "teardown: $label process(es) still running after SIGTERM, not force-killed: $(printf '%s' "$remaining" | tr '\n' ' ')" >&2
  return 0
}
