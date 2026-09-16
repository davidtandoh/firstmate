#!/usr/bin/env bash
# Token-free live guard: every installed harness must remain alive under Herdr
# despite absent/unknown registration, then become dead after its owned process
# is stopped. This guard proves process liveness, not native exit submission.
# All calls, including backend reads, pass through the named lab helper.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=tests/harness-live-helpers.sh
. "$ROOT/tests/harness-live-helpers.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
herdr_forget_inherited_pane
fm_live_gate default-on FM_HERDR_AGENT_LIVENESS_LIVE_E2E herdr jq

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name ak088-supervision-recovery)
TMP_ROOT=$(fm_test_tmproot fm-herdr-agent-liveness)
mkdir -p "$TMP_ROOT/cwd"
cleanup() {
  local status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() {
  [ "$1" = "$HERDR_LAB_SESSION" ] || return 9
  shift
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
herdr_version=$(lab status --json | jq -er '.server.version')
workspace=$(lab workspace create --label harness-liveness --cwd "$TMP_ROOT/cwd" --no-focus)
ws=$(printf '%s' "$workspace" | jq -er '.result.workspace.workspace_id')
checked=0

for harness in claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy; do
  if ! binary=$(fm_test_resolve_harness_binary "$harness"); then
    printf '# skip: %s is not installed; Herdr process liveness is unverified here\n' "$harness"
    continue
  fi
  version=$("$binary" --version 2>/dev/null | head -1) || version=unknown
  tab=$(lab tab create --workspace "$ws" --cwd "$TMP_ROOT/cwd" --label "$harness" --no-focus)
  pane=$(printf '%s' "$tab" | jq -er '.result.root_pane.pane_id')
  before=$(lab pane process-info --pane "$pane")
  shell_pid=$(printf '%s' "$before" | jq -er --arg pane "$pane" \
    '.result.process_info | select(.pane_id == $pane) | .shell_pid | select(type == "number" and . > 1)')
  shell_identity=$(fm_pid_identity "$shell_pid") || fail "$harness: pane shell identity is unreadable"
  args=''
  [ "$harness" != cursor ] || args=' --trust'
  launch=$(printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE %q%s' "$binary" "$args")
  lab pane run "$pane" "$launch" >/dev/null
  process=''
  for _ in $(seq 1 100); do
    process=$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$pane")
    [ "$process" != agent ] || break
    sleep 0.1
  done
  [ "$process" = agent ] || fail "Herdr $herdr_version + $harness $version: running harness process is not attributable ($process)"
  info=$(lab pane process-info --pane "$pane")
  child_pid=$(printf '%s' "$info" | jq -er --arg pane "$pane" --argjson shell "$shell_pid" \
    '.result.process_info | select(.pane_id == $pane and .shell_pid == $shell) | .foreground_process_group_id | select(type == "number" and . > 1)')
  child_identity=$(fm_pid_identity "$child_pid") || fail "$harness: native child start identity is unreadable"
  # These installed executables also participate in primary session ownership.
  # Check the shared identity and explicit-root walk without widening that table
  # to worker-only harnesses or claiming that a model received a Stop warning.
  if fm_harness_path_name "/$harness" >/dev/null || [ "$harness" = cursor ]; then
      fm_harness_pid_alive "$child_pid" || fail "$harness: native primary identity is not recognized"
      ownership_pids=$(fm_harness_ancestry_pids "$child_pid") \
        || fail "$harness: native explicit-root session ancestry is unreadable"
      printf '%s\n' "$ownership_pids" | grep -qx "$child_pid" \
        || fail "$harness: native session is absent from its own ownership ancestry"
      [ "$(fm_pid_identity "$child_pid")" = "$child_identity" ] \
        || fail "$harness: native identity changed during ownership reads"
      printf '# %s: native primary identity and explicit-root ownership ancestry verified\n' "$harness"
  fi
  registry=$(lab agent get "$pane" 2>&1) || true
  status=$(printf '%s' "$registry" | jq -r '.result.agent.agent_status // .error.code // "unreadable"')
  state=$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")
  [ "$state" = alive ] || fail "Herdr $herdr_version + $harness $version: verified process reads $state (registration $status)"
  printf '# Herdr %s + %s %s: process=agent registration=%s endpoint=alive\n' "$herdr_version" "$harness" "$version" "$status"
  pass "Herdr live harness: $harness $version remains alive independently of registration"
  sleep 1
  registry=$(lab agent get "$pane" 2>&1) || true
  status=$(printf '%s' "$registry" | jq -r '.result.agent.agent_status // .error.code // "unreadable"')
  state=$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")
  [ "$state" = alive ] || fail "Herdr $herdr_version + $harness $version: settled live process reads $state (registration $status)"
  printf '# Herdr %s + %s %s: settled registration=%s endpoint=alive\n' "$herdr_version" "$harness" "$version" "$status"

  # Test cleanup of one exact direct child, not a production control verb.
  # Revalidate the named pane, both process start identities, its shell parent,
  # and its foreground group immediately before signaling only that child.
  info=$(lab pane process-info --pane "$pane")
  printf '%s' "$info" | jq -e --arg pane "$pane" --argjson shell "$shell_pid" --argjson child "$child_pid" \
    '.result.process_info | .pane_id == $pane and .shell_pid == $shell and .foreground_process_group_id == $child' >/dev/null \
    || fail "$harness: pane ownership changed before process cleanup"
  [ "$child_pid" != "$shell_pid" ] && [ "$child_pid" != "$$" ] \
    || fail "$harness: refusing to signal a shell or the test process"
  parent=$(ps -p "$child_pid" -o ppid= | tr -d '[:space:]')
  group=$(ps -p "$child_pid" -o pgid= | tr -d '[:space:]')
  own_group=$(ps -p "$$" -o pgid= | tr -d '[:space:]')
  [ "$parent" = "$shell_pid" ] && [ "$group" = "$child_pid" ] && [ "$group" != "$own_group" ] \
    || fail "$harness: native process is not the pane's isolated direct child"
  [ "$(fm_pid_identity "$shell_pid")" = "$shell_identity" ] \
    && [ "$(fm_pid_identity "$child_pid")" = "$child_identity" ] \
    || fail "$harness: process start identity changed before cleanup"
  kill -KILL "$child_pid"
  for _ in $(seq 1 100); do
    process=$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$pane")
    [ "$process" != shell ] || break
    sleep 0.1
  done
  [ "$process" = shell ] || fail "Herdr $herdr_version + $harness $version: stopped harness did not leave its retained shell ($process)"
  state=$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")
  [ "$state" = dead ] || fail "Herdr $herdr_version + $harness $version: proven shell-only endpoint reads $state"
  pass "Herdr stopped harness: $harness $version leaves a recoverable shell after identity-bound test cleanup"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "Herdr $herdr_version: no installed harness checked; this run proves nothing"
printf '# checked %s installed harnesses; no prompt submitted\n' "$checked"
