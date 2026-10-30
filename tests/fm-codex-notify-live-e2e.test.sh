#!/usr/bin/env bash
# Credentialed direct + wrapped native completion and attached gate-return guard.
# Uses a private tmux socket and only the sessions this guard creates; no Herdr.
# Wrapped mode runs the managed Omnigent executable against a scratch server
# with its own config, data and database; it never contacts the managed service.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_NOTIFY_LIVE codex tmux agent-kit jq curl python3
TMP_ROOT=$(fm_test_tmproot fm-codex-notify-live)
version=$(codex --version)
original_codex_home=${CODEX_HOME:-$HOME/.codex}
original_home=$HOME
socket="$TMP_ROOT/tmux.sock"
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/home/data" "$TMP_ROOT/wt"
# A wrapped worker inherits its runner's OMNIGENT_* and OTEL_* environment,
# which points at the managed service; nothing here may inherit it.
clean_env=(env)
while IFS= read -r name; do clean_env+=(-u "$name"); done < <(compgen -e | grep -E '^(OMNIGENT|OTEL)_' || true)
scratch="$TMP_ROOT/omnigent"
mkdir -p "$scratch/config" "$scratch/data" "$scratch/kit"
executable=$("${clean_env[@]}" agent-kit observe serve status --readiness --json < /dev/null | jq -er .runtime.executable)
state_file=$("${clean_env[@]}" agent-kit observe serve status --json < /dev/null | jq -er .state_file)
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
server="http://127.0.0.1:$port"
server_pid=''
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
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  # The scratch host daemon and runners detach from this shell; stop exactly
  # the processes whose environment names this guard's scratch data directory.
  local pid
  while IFS= read -r pid; do
    ps eww -o command= -p "$pid" 2>/dev/null | grep -qF "OMNIGENT_DATA_DIR=$scratch/data" && kill "$pid" 2>/dev/null || true
  done < <(ps -axo pid= 2>/dev/null)
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
scratch_env=("${clean_env[@]}" "OMNIGENT_CONFIG_HOME=$scratch/config" "OMNIGENT_DATA_DIR=$scratch/data" OMNIGENT_TELEMETRY_ENABLED=false)
"${scratch_env[@]}" "$executable" server --host 127.0.0.1 --port "$port" --database-uri "sqlite:///$scratch/omnigent.db" \
  --artifact-location "$scratch/artifacts" --no-open > "$scratch/server.log" 2>&1 < /dev/null &
server_pid=$!
# The launch boundary reads service coordinates from Agent Kit. This shim
# reports the scratch server; the managed state path only anchors the
# executable's service-root check and is never read or written.
jq -n --arg server "$server" --arg state "$state_file" --arg config "$scratch/config" --arg data "$scratch/data" \
  '{status:"running",server_url:$server,state_file:$state,
    client_environment:{OMNIGENT_CONFIG_HOME:$config,OMNIGENT_DATA_DIR:$data,OMNIGENT_TELEMETRY_ENABLED:"false"}}' > "$scratch/status.json"
jq -n --arg server "$server" --arg executable "$executable" \
  '{schema_version:"1",status:"ready",reasons:[],managed_status:{status:"running"},
    managed_service:{server_url:$server},runtime:{executable:$executable}}' > "$scratch/readiness.json"
cat > "$scratch/kit/agent-kit" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  'observe serve status --json') cat '$scratch/status.json' ;;
  'observe serve status --readiness --json') cat '$scratch/readiness.json' ;;
  *) exit 2 ;;
esac
SHIM
chmod +x "$scratch/kit/agent-kit"
for _ in $(seq 1 600); do
  curl --silent --fail --max-time 2 "$server/health" >/dev/null 2>&1 && break
  kill -0 "$server_pid" 2>/dev/null || fail "scratch Omnigent server exited: $(tail -20 "$scratch/server.log")"
  sleep 0.1
done
curl --silent --fail --max-time 2 "$server/health" >/dev/null || fail 'scratch Omnigent server did not become healthy'
# Start the scratch host before the wrapped launch: a cold host can outlast
# the wrapper's fixed connect window on a busy machine.
"${scratch_env[@]}" "$executable" host --server "$server" --background --no-open --non-interactive \
  > "$scratch/host.log" 2>&1 < /dev/null || fail "scratch Omnigent host did not start: $(tail -20 "$scratch/host.log")"
for _ in $(seq 1 1800); do
  curl --silent --fail --max-time 2 "$server/v1/hosts" 2>/dev/null | jq -e 'any(.hosts[]?; .status == "online")' >/dev/null 2>&1 && break
  sleep 0.1
done
curl --silent --fail --max-time 2 "$server/v1/hosts" | jq -e 'any(.hosts[]?; .status == "online")' >/dev/null \
  || fail 'scratch Omnigent host did not come online'
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
  launch_env=("${clean_env[@]}")
  if [ "$mode" = wrapped ]; then
    launch_home=$original_home
    launch_env+=("PATH=$scratch/kit:$PATH")
  fi
  launch_script="$TMP_ROOT/$mode.launch.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexec ' > "$launch_script"
  printf '%q ' "${launch_env[@]}" HOME="$launch_home" CODEX_HOME="$original_codex_home" FM_HOME="$TMP_ROOT/home" FM_TASK_ID="$mode" \
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
