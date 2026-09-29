#!/usr/bin/env bash
# Live Omnigent foreground-process and native exit guard on a named Herdr lab.
# This opens real native sessions; run only against a healthy Kit serve.
# No prompt is submitted. Busy/turn-end and MLflow export require separate
# model-turn acceptance; this guard does not claim either from a live wrapper.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
. "$ROOT/tests/harness-live-helpers.sh"
fm_live_gate default-on FM_OMNIGENT_LIVE herdr agent-kit jq claude codex
# Refuse before provisioning if the host is not ready.
"$ROOT/bin/fm-omnigent.sh" check codex
herdr_forget_inherited_pane
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name omnigent-launch)
TMP_ROOT=$(fm_test_tmproot fm-omnigent-live)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/data" "$TMP_ROOT/home/config" "$TMP_ROOT/tools" "$TMP_ROOT/cwd"
cleanup() {
  local status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() {
  [ "$1" = "$HERDR_LAB_SESSION" ] || return 9
  shift
  lab "$@"
}
# Subprocess control reads also cross the exact same helper boundary.
export OMNI_REAL_PATH="$PATH" OMNI_LAB_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_HELPER
cat > "$TMP_ROOT/tools/herdr" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
args=(); seen=0
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$OMNI_LAB_SESSION" ] || exit 90
    seen=1; shift 2
  else
    args+=("$1"); shift
  fi
done
[ "$seen" = 1 ] || exit 91
PATH="$OMNI_REAL_PATH" "$HERDR_LAB_HELPER" run "$OMNI_LAB_SESSION" "${args[@]}"
SHIM
chmod +x "$TMP_ROOT/tools/herdr"
version=$(lab status --json | jq -er .server.version)
workspace=$(lab workspace create --label omnigent --cwd "$TMP_ROOT/cwd" --no-focus)
ws=$(printf '%s' "$workspace" | jq -er .result.workspace.workspace_id)
checked=0
for harness in claude codex kiro agy; do
  if ! binary=$(fm_test_resolve_harness_binary "$harness"); then
    printf '# skip: %s is not installed; Omnigent supervision unverified\n' "$harness"
    continue
  fi
  native_version=$("$binary" --version 2>/dev/null | head -1) || native_version=unknown
  "$ROOT/bin/fm-omnigent.sh" check "$harness" || fail "$harness $native_version: managed wrapper preflight failed"
  tab=$(lab tab create --workspace "$ws" --cwd "$TMP_ROOT/cwd" --label "$harness" --no-focus)
  pane=$(printf '%s' "$tab" | jq -er .result.root_pane.pane_id)
  tid=$(printf '%s' "$tab" | jq -er .result.tab.tab_id)
  args=()
  case "$harness" in
    claude) args=(--dangerously-skip-permissions '') ;;
    codex) args=(--dangerously-bypass-approvals-and-sandbox --disable hooks '') ;;
    kiro) args=(chat --agent-engine v3 --trust-all-tools '') ;;
    agy) args=(--dangerously-skip-permissions) ;;
  esac
  launch=$(printf '%q ' env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE "$ROOT/bin/fm-omnigent.sh" run "$harness" "${args[@]}")
  lab pane run "$pane" "$launch" >/dev/null
  state=''
  for _ in $(seq 1 100); do
    state=$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")
    [ "$state" != alive ] || break
    sleep 0.2
  done
  [ "$state" = alive ] || fail "Herdr $version + Omnigent $harness $native_version: expected alive, got $state"
  # Require the wrapper itself, so a native descendant cannot hide drift.
  # Herdr 0.9.1 on macOS supplies name, argv0, and pid, but no full argv.
  # Read that exact process through ps, as the backend's descendant walk does.
  # Shell startup/version and launch preflight processes are not the session.
  wrapper_state=other
  for _ in $(seq 1 100); do
    info=$(lab pane process-info --pane "$pane")
    wrapper=$(printf '%s' "$info" | jq -c '.result.process_info.foreground_processes[] | select(.name | test("^(python[0-9.]*|Python)$"))' | head -1)
    if [ -n "$wrapper" ]; then
      wrapper_pid=$(printf '%s' "$wrapper" | jq -er .pid)
      wrapper_args=$(LC_ALL=C ps -o command= -p "$wrapper_pid" 2>/dev/null) || wrapper_args=''
      case "$wrapper_args" in
        *" $harness --server "*)
          wrapper_state=$(fm_agent_process_classify \
            "$(printf '%s' "$wrapper" | jq -r .name)" \
            "$(printf '%s' "$wrapper" | jq -r '.argv[0] // .argv0 // empty')" \
            "$wrapper_args" "$wrapper_pid")
          [ "$wrapper_state" != agent ] || break
          ;;
      esac
    fi
    sleep 0.2
  done
  [ "$wrapper_state" = agent ] || fail "$harness $native_version: no attributable Python Omnigent foreground wrapper"
  printf '# Herdr %s + Omnigent %s %s: alive; wrapper classified from ordered argv\n' "$version" "$harness" "$native_version"
  # Native startup follows wrapper startup. Let the shared composer reader
  # prove readiness before the control plane attempts a native exit command.
  composer=unknown
  for _ in $(seq 1 100); do
    composer=$(fm_backend_herdr_composer_state "$HERDR_LAB_SESSION:$pane")
    [ "$composer" != empty ] || break
    sleep 0.2
  done
  if [ "$composer" != empty ]; then
    lab pane read "$pane" --source recent --lines 30 >&2
    fail "$harness $native_version: native composer is $composer after startup"
  fi
  cat > "$TMP_ROOT/home/state/probe.meta" <<META
window=$HERDR_LAB_SESSION:$pane
endpoint_task_id=probe
worktree=$TMP_ROOT/cwd
project=$ROOT
harness=$harness
kind=scout
mode=scout
yolo=off
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tid
herdr_pane_id=$pane
omnigent=on
META
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$TMP_ROOT/tools:$PATH" FM_HOME="$TMP_ROOT/home" \
    "$ROOT/bin/fm-control.sh" probe exit || fail "$harness $native_version: native exit did not stop the wrapped session"
  [ "$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")" = dead ] \
    || fail "$harness $native_version: native exit left a live wrapper"
  pass "Omnigent $harness $native_version: liveness and native exit"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'no installed native harness was checked'
