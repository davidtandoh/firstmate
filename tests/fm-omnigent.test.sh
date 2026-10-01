#!/usr/bin/env bash
# Contracts for the Omnigent launch boundary and its observed process shapes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-agent-process-lib.sh"

for harness in claude codex kiro agy antigravity; do
  got=$(fm_agent_process_classify_name python3.12 python3 "/home/user/serve/runtime/bin/python3 /home/user/serve/runtime/bin/omnigent $harness --server http://127.0.0.1:6767")
  [ "$got" = agent ] || fail "Omnigent $harness Python wrapper should be an agent, got $got"
  got=$(fm_agent_process_classify_name python3.12 python3 "/home/user/serve/runtime/bin/python3 -P -m omnigent.cli $harness --server http://127.0.0.1:6767")
  [ "$got" = agent ] || fail "Omnigent $harness module wrapper should be an agent, got $got"
done
for args in \
  'python3 -P -m omnigent.cli server' \
  'python3 -P -m omnigent.cli --version' \
  'python3 -P -m omnigent.host._daemon_entry --local' \
  'python3 -P -m omnigent.cli codex-helper' \
  'python3 -P -m omnigent.client codex' \
  'python3 /tmp/probe.py -P -m omnigent.cli codex' \
  'python3 /home/user/bin/omnigent server' \
  'python3 /home/user/bin/omnigent host' \
  'python3 /tmp/probe.py omnigent codex' \
  'python3 -c print(omnigent) codex' \
  'python3 /tmp/not-omnigent codex'; do
  got=$(fm_agent_process_classify_name python3.12 python3 "$args")
  [ "$got" = other ] || fail "non-agent command was classified $got: $args"
done
pass 'only native Omnigent launch commands identify an agent'

TMP_ROOT=$(fm_test_tmproot fm-omnigent)
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/config" "$TMP_ROOT/tools" "$TMP_ROOT/serve/runtime/bin"
export HOME="$TMP_ROOT/home"
OMNI="$ROOT/bin/fm-omnigent.sh"
mode() { env -u FM_OMNIGENT -u OMNIGENT "$OMNI" mode "$TMP_ROOT/config"; }
[ "$(mode)" = off ] || fail 'ordinary sessions must stay native'
[ "$(OMNIGENT=1 "$OMNI" mode "$TMP_ROOT/config")" = on ] || fail 'verified Omnigent marker must enable wrapping'
printf 'off\n' > "$TMP_ROOT/config/omnigent"
for marker in 0 1; do
  if OMNIGENT="$marker" "$OMNI" mode "$TMP_ROOT/config" > "$TMP_ROOT/error" 2>&1; then fail 'removed home opt-out accepted'; fi
done
printf 'on\n' > "$TMP_ROOT/config/omnigent"
[ "$(mode)" = on ] || fail 'home opt-in must work without detection'
printf 'auto\n' > "$TMP_ROOT/config/omnigent"
[ "$(FM_OMNIGENT=on "$OMNI" mode "$TMP_ROOT/config")" = on ] || fail 'inherited session mode must reach a secondmate'
[ "$(FM_OMNIGENT=off OMNIGENT=1 "$OMNI" mode "$TMP_ROOT/config")" = on ] || fail 'inherited native mode disabled detection'
[ "$(env -u OMNIGENT FM_OMNIGENT=off "$OMNI" mode "$TMP_ROOT/config")" = off ] || fail 'ordinary inherited native mode changed'
if FM_OMNIGENT=typo "$OMNI" mode "$TMP_ROOT/config" > "$TMP_ROOT/error" 2>&1; then fail 'invalid inherited mode accepted'; fi
printf 'typo\n' > "$TMP_ROOT/config/omnigent"
if mode > "$TMP_ROOT/error" 2>&1; then fail 'invalid home policy accepted'; fi
rm "$TMP_ROOT/config/omnigent"
ln -s "$TMP_ROOT/home" "$TMP_ROOT/config/omnigent"
if mode > "$TMP_ROOT/error" 2>&1; then fail 'symlink home policy accepted'; fi
rm "$TMP_ROOT/config/omnigent"
pass 'session detection, explicit home policy, and inherited mode fail closed'

. "$ROOT/tests/omnigent-fixture.sh"
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH"
OMNI_STATUS="$TMP_ROOT/serve/status.json"
OMNI_RESULT="$TMP_ROOT/serve/result.json"
"$OMNI" check codex
LC_ALL=C "$OMNI" run codex 'locale probe'
jq -e '.client_encoding == "UTF-8"' "$OMNI_RESULT" >/dev/null \
  || fail 'Omnigent attach must preserve native glyphs under an ASCII supervisor locale'
cat > "$TMP_ROOT/tools/locale" <<'SHIM'
#!/usr/bin/env bash
printf 'C\nPOSIX\n'
SHIM
chmod +x "$TMP_ROOT/tools/locale"
rm "$OMNI_RESULT"
if LC_ALL=C "$OMNI" run codex 'locale probe' > "$TMP_ROOT/error" 2>&1; then
  fail 'launch without an installed UTF-8 locale was accepted'
fi
[ ! -e "$OMNI_RESULT" ] || fail 'missing locale launched Omnigent'
grep -q 'UTF-8 locale' "$TMP_ROOT/error" || fail 'missing locale refusal is not actionable'
rm "$TMP_ROOT/tools/locale"
pass 'Omnigent attach uses UTF-8 or refuses before native launch'
# shellcheck disable=SC2016 # Literal shell syntax must survive the launch unchanged.
env -u FM_ROOT_OVERRIDE FM_HOME="$TMP_ROOT/secondmate" COMPACT_ADVISER_DISABLE=1 FM_OMNIGENT=on \
  "$OMNI" run codex --model chosen-model -c 'model_reasoning_effort="high"' --disable hooks 'literal $HOME; $(false)'
jq -e --arg home "FM_HOME=$TMP_ROOT/secondmate" '
  .config_home != null and
  (.argv | index($home)) != null and
  (.argv | index("COMPACT_ADVISER_DISABLE=1")) != null and
  (.argv | index("FM_OMNIGENT=on")) != null and
  (.argv | index("FM_ROOT_OVERRIDE=")) != null and
  (.argv | index("chosen-model")) != null and
  (.argv | index("model_reasoning_effort=\"high\"")) != null and
  (.argv | index("literal $HOME; $(false)")) != null
' "$OMNI_RESULT" >/dev/null || fail 'launch lost native arguments or owned environment'
pass 'managed executable receives exact arguments and explicit worker environment'

if OMNI_HEALTH=down "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'unreachable server accepted'; fi
printf '{"status":"stopped","reason":"not_started"}\n' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'stopped server accepted'; fi
grep -q 'not_started' "$TMP_ROOT/error" || fail 'refusal omitted concrete service reason'
printf '{bad json' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'malformed service response accepted'; fi
if "$OMNI" check pi > "$TMP_ROOT/error" 2>&1; then fail 'unverified wrapped harness accepted'; fi
pass 'missing, unreachable, malformed service and unverified harness refuse'

. "$ROOT/tests/fixtures.sh"
spawn_home="$TMP_ROOT/spawn-home"
spawn_project="$TMP_ROOT/project"
spawn_wt="$TMP_ROOT/worktree"
spawn_tools=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-tools")
fm_test_spawn_home "$spawn_home" codex
fm_git_worktree "$spawn_project" "$spawn_wt" omni-fixture
fm_test_spawn_brief "$spawn_home" omni-test
printf '{"status":"stopped","reason":"not_started"}\n' > "$OMNI_STATUS"
if FM_OMNIGENT=on FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" \
  fm_test_run_spawn "$spawn_home" "$spawn_wt" "$spawn_tools" omni-test "$spawn_project" --mode no-mistakes --yolo off > "$TMP_ROOT/error" 2>&1; then
  fail 'spawn proceeded with a stopped Omnigent server'
fi
[ ! -e "$spawn_home/state/omni-test.meta" ] || fail 'refused spawn published task metadata'
grep -q not_started "$TMP_ROOT/error" || fail 'spawn did not report service refusal'
pass 'spawn refuses before endpoint publication when tracing is unavailable'

# Execute the launch the pane received, using the service double to observe
# the native argv and environment beyond the daemon boundary.
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
launch_log="$TMP_ROOT/launch.log"
pane_log="$TMP_ROOT/pane.log"
spawn() {
  : > "$launch_log"; : > "$pane_log"
  FM_FAKE_LAUNCH_LOG="$launch_log" FM_FAKE_PANE_LOG="$pane_log" \
    fm_test_run_spawn "$spawn_home" "$spawn_wt" "$spawn_tools" "$@"
}
execute_launch() {
  local launch preamble
  launch=$(cat "$launch_log")
  preamble=$(grep '^export ' "$pane_log" || true)
  env -i HOME="$TMP_ROOT/home" PATH="$spawn_tools:$PATH" TERM=xterm /bin/sh -c "$preamble
$launch"
}
for kind in ship scout; do
  id="omni-$kind"
  fm_test_spawn_brief "$spawn_home" "$id"
  args=(--mode no-mistakes --yolo off)
  [ "$kind" != scout ] || args=(--scout)
  FM_OMNIGENT=on spawn "$id" "$spawn_project" "${args[@]}" --harness codex --model gpt-5.4 --effort high > "$TMP_ROOT/output" 2>&1 || fail "wrapped $kind spawn: $(cat "$TMP_ROOT/output")"
  execute_launch
  jq -e '.argv[0] == "codex" and (.argv | index("gpt-5.4")) != null and
    (.argv | index("model_reasoning_effort=\"high\"")) != null and
    (.argv | any(.[]; startswith("notify="))) and
    .environment.FM_OMNIGENT == "on" and .environment.COMPACT_ADVISER_DISABLE == "1"' "$OMNI_RESULT" >/dev/null || fail "$kind lost dispatch, turn-end notification, or session propagation"
  grep -qx 'omnigent=on' "$spawn_home/state/$id.meta" || fail "$kind metadata lost wrapping"
done
pass 'ship and scout pane launches preserve dispatch, notify, and explicit session environment'

printf 'on\n' > "$spawn_home/config/omnigent"
sm="$TMP_ROOT/secondmate"
mkdir -p "$sm/bin" "$sm/data"
printf '# Firstmate\n' > "$sm/AGENTS.md"
printf 'omni-sm\n' > "$sm/.fm-secondmate-home"
printf 'Test charter\n' > "$sm/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
git -C "$sm" init -q -b main
FM_OMNIGENT=on spawn omni-sm "$sm" --secondmate > "$TMP_ROOT/output" 2>&1 || fail "secondmate spawn: $(cat "$TMP_ROOT/output")"
execute_launch
jq -e --arg home "$sm" '.environment.FM_HOME == $home and .environment.FM_OMNIGENT == "on" and
  .environment.FM_ROOT_OVERRIDE == "" and (.argv | index("hooks")) == null' "$OMNI_RESULT" >/dev/null || fail 'secondmate lost its home, inherited mode, or primary hooks'
# This is the mode the child spawn resolves, with no native marker or parent env.
[ "$(cat "$sm/config/omnigent")" = on ] || fail 'home policy was not inherited'
child_mode=$(jq -r .environment.FM_OMNIGENT "$OMNI_RESULT")
[ "$(env -u OMNIGENT FM_OMNIGENT="$child_mode" "$OMNI" mode "$sm/config")" = on ] || fail 'secondmate cannot propagate to its own workers'
pass 'local secondmate receives its isolated home and passes mode to its own workers'

printf 'auto\n' > "$spawn_home/config/omnigent"
printf '{"status":"stopped","reason":"not_started"}\n' > "$OMNI_STATUS"
fm_test_spawn_brief "$spawn_home" omni-native
spawn omni-native "$spawn_project" --mode no-mistakes --yolo off > "$TMP_ROOT/output" 2>&1 || fail 'ordinary native launch refused with stopped serve'
cat > "$spawn_tools/codex" <<'PROBE'
#!/bin/sh
printf 'native-codex\n'
PROBE
chmod +x "$spawn_tools/codex"
[ "$(execute_launch)" = native-codex ] || fail 'ordinary native launch did not execute the original harness'
pass 'ordinary sessions preserve direct launch while serve is unavailable'

# Restrictions must refuse before launching and must not weaken either policy.
printf 'on\n' > "$spawn_home/config/omnigent"
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
: > "$spawn_home/config/launch-env-allowlist"
fm_test_spawn_brief "$spawn_home" omni-restricted
if spawn omni-restricted "$spawn_project" --mode no-mistakes --yolo off > "$TMP_ROOT/error" 2>&1; then fail 'environment clearing contract was silently weakened'; fi
grep -q 'cannot enforce config/launch-env-allowlist' "$TMP_ROOT/error" || fail 'allowlist refusal omitted requirement'
rm "$spawn_home/config/launch-env-allowlist"
printf 'personal\n' > "$spawn_home/config/claude-account"
if spawn omni-restricted "$spawn_project" --mode no-mistakes --yolo off --harness claude > "$TMP_ROOT/error" 2>&1; then fail 'account removal contract was silently weakened'; fi
grep -q 'cannot enforce config/claude-account' "$TMP_ROOT/error" || fail 'account refusal omitted requirement'
[ "$(cat "$spawn_home/config/claude-account")" = personal ] || fail 'spawn altered the account pin'
pass 'wrapped launches refuse guarantees the additive daemon environment cannot enforce'

# Validate data from the service rather than evaluating it as shell syntax.
for invalid in \
  '.server_url="https://external.example"' \
  '.client_environment={}' \
  '.client_environment.PATH="/tmp/override"' \
  '.client_environment.OTEL_BAD="line\nbreak"' \
  '.state_file="relative/serve.json"'; do
  fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
  jq "$invalid" "$OMNI_STATUS" > "$TMP_ROOT/invalid.json"
  mv "$TMP_ROOT/invalid.json" "$OMNI_STATUS"
  if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail "invalid status accepted: $invalid"; fi
done
pass 'service coordinates and client environment are validated as data'
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
"$OMNI" run claude --model claude-opus-4-6 --effort high --settings '{"hooks":{}}' 'initial prompt'
jq -e '(.argv | index("--use-native-config")) != null and (.argv | index("{\"hooks\":{}}")) != null and (.argv | index("initial prompt")) != null' "$OMNI_RESULT" >/dev/null || fail 'Claude native config or hooks changed'
"$OMNI" run kiro chat --agent-engine v3 --model claude-opus-4-6 --effort high --trust-all-tools 'initial prompt'
jq -e '(.argv | index("chat")) == null and (.argv | index("--agent-engine")) != null and (.argv | index("v3")) != null and (.argv | index("--trust-all-tools")) != null' "$OMNI_RESULT" >/dev/null || fail 'Kiro wrapper duplicated chat or dropped native flags'
"$OMNI" run agy --prompt-interactive 'initial prompt' --model gemini-2.5-pro --dangerously-skip-permissions
jq -e '(.argv | index("--prompt-interactive")) != null and (.argv | index("gemini-2.5-pro")) < (.argv | index("--"))' "$OMNI_RESULT" >/dev/null || fail 'Antigravity native arguments changed'
rm "$OMNI_RESULT"
"$OMNI" start --dry-run codex > "$TMP_ROOT/preview.json"
[ ! -e "$OMNI_RESULT" ] || fail 'dry run started a session'
jq -e '.harness == "codex" and .server_url == "http://127.0.0.1:6767"' "$TMP_ROOT/preview.json" >/dev/null || fail 'dry run omitted the resolved service'
"$OMNI" start codex
jq -e '.argv[-1] == "--" and .environment.FM_OMNIGENT == "on"' "$OMNI_RESULT" >/dev/null || fail 'primary start did not carry native mode or added an empty argument'
pass 'native wrapper argument contracts and primary start preserve exact boundaries'

for harness in claude codex; do
  for backend in herdr unset empty; do
    backend_env=("FM_BACKEND=$backend")
    expected_backend=$backend
    if [ "$backend" = unset ]; then backend_env=(-u FM_BACKEND); expected_backend=tmux; fi
    if [ "$backend" = empty ]; then backend_env=('FM_BACKEND='); expected_backend=tmux; fi
    env "${backend_env[@]}" FM_HOME="$TMP_ROOT/home" "$OMNI" start "$harness"
    python3 - "$OMNI_RESULT" "$ROOT/bin/fm-backend.sh" "$expected_backend" <<'PY'
from __future__ import annotations

import json
import os
import subprocess
import sys

with open(sys.argv[1], encoding="utf-8") as result:
    native = json.load(result)["environment"]
expected = sys.argv[3]
assert native["FM_BACKEND"] == ("" if expected == "tmux" else expected), native
daemon = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
          "FM_BACKEND": "orca", "TMUX": "/fixture/omnigent-tmux,1,0"}
daemon.update(native)
selected = subprocess.check_output(
    ["bash", "-c", '. "$1"; fm_backend_name', "_", sys.argv[2]],
    env=daemon, text=True).strip()
assert selected == expected, (selected, expected)
PY
  done
done
pass 'primary starts preserve backend overrides and clear stale daemon selection'
