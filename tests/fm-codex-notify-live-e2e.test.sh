#!/usr/bin/env bash
# Credentialed direct + wrapped native completion and attached gate-return guard.
# Uses a private tmux socket and only the sessions this guard creates; no Herdr.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_NOTIFY_LIVE codex tmux agent-kit jq curl
TMP_ROOT=$(fm_test_tmproot fm-codex-notify-live)
version=$(codex --version)
original_codex_home=${CODEX_HOME:-$HOME/.codex}
original_home=$HOME
server=$(bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex | jq -er .server_url)
socket="$TMP_ROOT/tmux.sock"
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/home/data" "$TMP_ROOT/wt"
state="$TMP_ROOT/home/state"
wt="$TMP_ROOT/wt"
# The synthetic drive returns a real gate after its process exits. The model
# must read it and issue exactly one response; no shared validation run is used.
cat > "$TMP_ROOT/gate.py" <<'PY'
from __future__ import annotations
import json, pathlib, sys, time
root=pathlib.Path(__file__).parent
if len(sys.argv)==1:
    time.sleep(3)
    print(json.dumps({'gate':'approval','action':'Run python3 '+str(__file__)+' respond exactly once, then finish.'}))
else:
    with (root/'responses').open('a') as output:
        output.write('respond\n')
    print('Gate handled; completion confirmed.')
PY
cleanup() {
  local binding session resources terminal
  binding="$state/wrapped.codex-native.json"
  if [ -f "$binding" ]; then
    session=$(jq -er .session_id "$binding") || session=''
    if [[ "$session" =~ ^[a-f0-9]{32}$ ]]; then
      resources=$(curl --silent --show-error --fail --max-time 5 "$server/v1/sessions/$session/resources/terminals") || resources=''
      while IFS= read -r terminal; do
        [[ "$terminal" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        curl --silent --show-error --fail --max-time 5 -X DELETE "$server/v1/sessions/$session/resources/terminals/$terminal" >/dev/null || true
      done < <(printf '%s' "$resources" | jq -r --arg session "$session" '.data[] | select(.session_id == $session and .type == "terminal") | .id' 2>/dev/null)
    fi
  fi
  tmux -S "$socket" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Render the actual default pause instructions; the flag is deliberately absent.
FM_HOME="$TMP_ROOT/home" bash "$ROOT/bin/fm-brief.sh" wait-source firstmate --scout >/dev/null
# shellcheck disable=SC2016 # Literal markup in the generated pause contract.
pause_guidance=$(sed -n '/Use `paused: {why}`/,/Use `blocked:` when you are stuck/p' "$TMP_ROOT/home/data/wait-source/brief.md")
for mode in direct wrapped; do
  rm -f "$TMP_ROOT/responses"
  gen="s$(date +%s).$$.$RANDOM"
  omni=off
  [ "$mode" != wrapped ] || omni=on
  printf 'worktree=%s\nharness=codex\nkind=scout\nspawn_gen=%s\nomnigent=%s\nmodel=gpt-6.1-sol\n' "$wt" "$gen" "$omni" > "$state/$mode.meta"
  brief="$TMP_ROOT/$mode.md"
  printf 'This is a bounded harness test. Do not launch agents or inspect other directories.\n%s\nRun python3 %s/gate.py, read its returned gate, and handle that gate exactly once before replying COMPLETE.\n' "$pause_guidance" "$TMP_ROOT" > "$brief"
  prompt=$(bash "$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$brief")
  notify=$(jq -cn --arg handler "$ROOT/bin/fm-codex-native.sh" --arg state "$state" --arg id "$mode" --arg gen "$gen" --arg brief "$brief" '["bash",$handler,"notify",$state,$id,$gen,$brief]')
  launch=(codex)
  if [ "$mode" = wrapped ]; then launch=(bash "$ROOT/bin/fm-omnigent.sh" run codex); fi
  # An isolated HOME contains task state; CODEX_HOME explicitly selects the
  # credentialed native configuration for direct mode. Wrapped mode provisions
  # its own session-private native home through the managed service, whose
  # preflight must resolve the installed Kit from the real operator HOME.
  launch_home="$TMP_ROOT/home"
  [ "$mode" != wrapped ] || launch_home=$original_home
  launch_script="$TMP_ROOT/$mode.launch.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexec ' > "$launch_script"
  printf '%q ' env HOME="$launch_home" CODEX_HOME="$original_codex_home" FM_HOME="$TMP_ROOT/home" FM_TASK_ID="$mode" \
    "${launch[@]}" --model gpt-6.1-sol -c 'model_reasoning_effort="low"' --disable hooks \
    --dangerously-bypass-approvals-and-sandbox -c "notify=$notify" "$prompt" >> "$launch_script"
  printf '2> %q\n' "$TMP_ROOT/$mode.stderr" >> "$launch_script"
  tmux -S "$socket" new-session -d -s "$mode" -x 150 -y 40 -c "$wt" bash "$launch_script"
  for _ in $(seq 1 1200); do
    [ ! -f "$state/$mode.turn-ended" ] || break
    tmux -S "$socket" has-session -t "$mode" 2>/dev/null || fail "$version $mode launch exited: $(cat "$TMP_ROOT/$mode.stderr")"
    sleep 0.1
  done
  tmux -S "$socket" capture-pane -p -t "$mode" -S -100 > "$TMP_ROOT/$mode.screen"
  [ -f "$state/$mode.turn-ended" ] || fail "$version $mode: genuine completion did not signal: $(tail -12 "$TMP_ROOT/$mode.screen")"
  [ "$(cat "$TMP_ROOT/responses")" = respond ] || fail "$version $mode: returned gate was not handled exactly once"
  jq -e --arg gen "$gen" '.generation == $gen and (.thread_id | length > 0)' "$state/$mode.turn-ended" >/dev/null || fail "$version $mode: marker lacks native identity"
  pass "$version $mode: tools start without a nudge; returned gate is handled once; canonical completion signals"
done
