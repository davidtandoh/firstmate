#!/usr/bin/env bash
# Contracts for the Omnigent launch boundary and its observed process shapes.
# Run with --claude-accounts for focused Claude account boundary checks.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-agent-process-lib.sh"

if [ "${1:-}" != --claude-accounts ]; then
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
fi

TMP_ROOT=$(fm_test_tmproot fm-omnigent)
native_pid=''
cleanup() {
  if [ -n "$native_pid" ]; then
    kill -TERM "$native_pid" 2>/dev/null || true
    wait "$native_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/config" "$TMP_ROOT/tools" "$TMP_ROOT/serve/runtime/bin"
export HOME="$TMP_ROOT/home"
OMNI="$ROOT/bin/fm-omnigent.sh"
if [ "${1:-}" != --claude-accounts ]; then
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
fi

. "$ROOT/tests/omnigent-fixture.sh"
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH"
OMNI_STATUS="$TMP_ROOT/serve/status.json"
OMNI_RESULT="$TMP_ROOT/serve/result.json"
"$OMNI" check codex
cp "$OMNI_STATUS" "$TMP_ROOT/enforcing-status.json"
jq '.omnigent.commit="f165e117cfefa08df674d5a837025f51b7834536"' "$TMP_ROOT/enforcing-status.json" > "$OMNI_STATUS"
CLAUDE_CONFIG_DIR='' "$OMNI" run claude 'personal default'
jq -e '.environment | has("CLAUDE_CONFIG_DIR") | not' "$OMNI_RESULT" >/dev/null || fail 'legacy personal launch received an account override'
if CLAUDE_CONFIG_DIR="$HOME/.claude_b" "$OMNI" check claude > "$TMP_ROOT/error" 2>&1; then fail 'legacy daemon accepted GuideX'; fi
grep -q 'running daemon lacks verified exact Claude account enforcement' "$TMP_ROOT/error" || fail 'legacy account refusal omitted requirement'
cp "$TMP_ROOT/enforcing-status.json" "$OMNI_STATUS"
CLAUDE_CONFIG_DIR="$HOME/.claude_b/" "$OMNI" check claude
# The running fork build descends from the enforcing commit and is admitted.
jq '.omnigent.commit="bbda8af3d7e7792b16d957cfdadd116449712135"' "$TMP_ROOT/enforcing-status.json" > "$OMNI_STATUS"
CLAUDE_CONFIG_DIR="$HOME/.claude_b" "$OMNI" run claude 'GuideX account'
jq -e --arg root "$HOME/.claude_b" '.environment.CLAUDE_CONFIG_DIR == $root' "$OMNI_RESULT" >/dev/null \
  || fail 'admitted daemon build did not receive the selected Claude account'
cp "$TMP_ROOT/enforcing-status.json" "$OMNI_STATUS"
CLAUDE_CONFIG_DIR='' "$OMNI" run claude 'personal default'
jq -e '.environment | has("CLAUDE_CONFIG_DIR") | not' "$OMNI_RESULT" >/dev/null || fail 'empty personal selector reached the daemon boundary'
env -u CLAUDE_CONFIG_DIR "$OMNI" run claude 'unconfigured default'
jq -e '.environment | has("CLAUDE_CONFIG_DIR") | not' "$OMNI_RESULT" >/dev/null || fail 'unset default selector was changed at the daemon boundary'


# The CLI double emits its own fresh session record on stderr. Drive the real
# launcher, then observe the API requests rather than inspecting launcher text.
wait_title() {
  local attempt
  for ((attempt = 1; attempt <= 80; attempt++)); do
    [ ! -f "$TMP_ROOT/serve/title.json" ] || return 0
    sleep 0.1
  done
  fail 'launch did not PATCH its session title'
}
reset_title() { rm -f "$TMP_ROOT/serve/title.json" "$TMP_ROOT/serve/requests.jsonl"; }
if [ "${1:-}" != --claude-accounts ]; then
for harness in claude codex; do
  reset_title
  env -u FM_TASK_ID -u FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_HOME="$TMP_ROOT/main" \
    "$OMNI" start "$harness" 2> "$TMP_ROOT/title-error"
  wait_title
  jq -e '.title == "firstmate"' "$TMP_ROOT/serve/title.json" >/dev/null || fail 'main title differs'
  jq -se 'length == 4 and .[0].url == "http://127.0.0.1:6767/health" and
    .[1].event == "launch" and .[2].method == "GET" and .[3].method == "PATCH" and
    .[2].url == "http://127.0.0.1:6767/v1/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
    .[3].url == .[2].url and .[3].body == {title:"firstmate"}' \
    "$TMP_ROOT/serve/requests.jsonl" >/dev/null || fail 'title requests escaped exact launch ordering or target'
  printf 'Web UI: http://127.0.0.1:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$TMP_ROOT/expected-stderr"
  cmp "$TMP_ROOT/expected-stderr" "$TMP_ROOT/title-error" || fail 'native stderr changed'
done
reset_title
env -u FM_TASK_ID -u FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_HOME="$TMP_ROOT/main" FM_FRESH_TOKEN=handoff-proof \
  "$OMNI" run claude 'Continue Firstmate' 2> "$TMP_ROOT/title-error"
wait_title
jq -e '.title == "firstmate"' "$TMP_ROOT/serve/title.json" >/dev/null || fail 'fresh primary title differs'
jq -e '.environment.FM_FRESH_TOKEN == "handoff-proof" and .environment.FM_TASK_ID == "" and
  (.argv | index("--prompt")) != null' "$OMNI_RESULT" >/dev/null || fail 'fresh launch lost token or initial prompt'
pass 'fresh primary launch keeps the firstmate title and forwards its handoff token'

for harness in claude codex kiro agy; do
  reset_title
  native=('literal prompt')
  [ "$harness" != kiro ] || native=(chat 'literal prompt')
  [ "$harness" != agy ] || native=(--prompt-interactive 'literal prompt')
  FM_HOME="$TMP_ROOT/worker-home" FM_TASK_ID=title-task "$OMNI" run "$harness" "${native[@]}" 2> "$TMP_ROOT/title-error"
  wait_title
  jq -e '.title == "worker-home · title-task"' "$TMP_ROOT/serve/title.json" >/dev/null || fail "$harness worker title differs"
done
reset_title
env -u FM_TASK_ID FM_HOME="$TMP_ROOT/secondmate" FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$TMP_ROOT/main" \
  "$OMNI" run codex '' 2> "$TMP_ROOT/title-error"
wait_title
jq -e '.title == "secondmate · firstmate"' "$TMP_ROOT/serve/title.json" >/dev/null || fail 'secondmate primary title differs'
pass 'main, every wrapped worker, and secondmate primary receive exact role titles'

for title_mode in http-error wrong-id wrong-harness old-session wrong-title invalid-json oversized slow; do
  reset_title
  rc=0
  OMNI_TITLE_MODE=$title_mode OMNI_EXIT=37 "$OMNI" start codex 2> "$TMP_ROOT/title-error" || rc=$?
  [ "$rc" = 37 ] || fail 'naming changed native exit status'
  for _ in $(seq 1 160); do
    if grep -q 'error: Omnigent session title:' "$TMP_ROOT/title-error"; then break; fi
    sleep 0.1
  done
  grep -q 'error: Omnigent session title:' "$TMP_ROOT/title-error" || fail "$title_mode did not report bounded naming failure"
  if [ "$title_mode" != wrong-title ]; then
    [ ! -f "$TMP_ROOT/serve/title.json" ] || fail "$title_mode renamed an unverified session"
  fi
done
for record_mode in missing wrong-server malformed; do
  reset_title
  OMNI_RECORD_MODE=$record_mode "$OMNI" start codex 2> "$TMP_ROOT/title-error"
  for _ in $(seq 1 80); do
    if grep -q 'error: Omnigent session title:' "$TMP_ROOT/title-error"; then break; fi
    sleep 0.1
  done
  grep -q 'error: Omnigent session title:' "$TMP_ROOT/title-error" || fail "$record_mode did not report missing launch identity"
  [ ! -f "$TMP_ROOT/serve/title.json" ] || fail "$record_mode renamed a session"
  jq -se 'length == 2 and .[0].url == "http://127.0.0.1:6767/health" and .[1].event == "launch"' \
    "$TMP_ROOT/serve/requests.jsonl" >/dev/null || fail "$record_mode issued a session API request without launch identity"
done
pass 'naming fails visibly within bounds and preserves the native launch exit status'

reset_title
OMNI_RECORD_MODE=fragmented OMNI_STDOUT_RECORD=1 "$OMNI" start codex > "$TMP_ROOT/native-stdout" 2> "$TMP_ROOT/title-error"
wait_title
jq -e '.id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$TMP_ROOT/serve/title.json" >/dev/null || fail 'stdout decoy selected another session'
grep -q bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$TMP_ROOT/native-stdout" || fail 'native stdout changed'
printf '\r\033[2KWeb UI: http://127.0.0.1:6767/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$TMP_ROOT/expected-stderr"
cmp "$TMP_ROOT/expected-stderr" "$TMP_ROOT/title-error" || fail 'fragmented stderr bytes changed'

reset_title
OMNI_HOLD=1 "$OMNI" start codex > "$TMP_ROOT/native-stdout" 2> "$TMP_ROOT/title-error" &
native_pid=$!
wait_title
jq -e --argjson pid "$native_pid" '.pid == $pid' "$OMNI_RESULT" >/dev/null || fail 'launcher stopped execing the native wrapper'
kill -TERM "$native_pid"
rc=0
wait "$native_pid" || rc=$?
native_pid=''
[ "$rc" = 143 ] || fail 'TERM or its exit status was intercepted by title observation'

reset_title
FM_TEST_OMNIGENT_TITLE_WAIT=1 OMNI_RECORD_MODE=missing OMNI_HOLD=1 \
  "$OMNI" start codex > "$TMP_ROOT/native-stdout" 2> "$TMP_ROOT/title-error" &
native_pid=$!
for _ in $(seq 1 80); do
  if grep -q 'timed out waiting' "$TMP_ROOT/title-error"; then break; fi
  sleep 0.1
done
grep -q 'timed out waiting' "$TMP_ROOT/title-error" || fail 'missing record was not bounded while native launch stayed alive'
kill -0 "$native_pid" || fail 'record deadline stopped the native session'
kill -TERM "$native_pid"
wait "$native_pid" || true
native_pid=''
pass 'private stderr observation preserves bytes, foreground exec identity, signals and bounded record waiting'

# Selection is read for every operation; the retained executable stays present.
readiness="$TMP_ROOT/serve/readiness.json"
cp "$readiness" "$TMP_ROOT/headless.json"
web="$TMP_ROOT/serve/generations/web/runtime/bin/omnigent"
mkdir -p "$(dirname "$web")"
cp "$TMP_ROOT/serve/runtime/bin/omnigent" "$web"
jq --arg executable "$web" '.status="ready" | .reasons=[] | .runtime.executable=$executable' \
  "$readiness" > "$TMP_ROOT/web.json"
for selected in web headless web; do
  cp "$TMP_ROOT/$selected.json" "$readiness"
  expected=$(jq -r .runtime.executable "$readiness")
  for harness in claude codex kiro agy; do
    "$OMNI" check "$harness"
    "$OMNI" run --dry-run "$harness" > "$TMP_ROOT/preview.json"
    jq -e --arg expected "$expected" '.executable == $expected' "$TMP_ROOT/preview.json" >/dev/null || fail 'dry run cached a generation'
  done
  "$OMNI" start codex
  jq -e --arg expected "$expected" '.executable == $expected' "$OMNI_RESULT" >/dev/null || fail 'launch used the wrong generation'
done
pass 'check, dry run, and launch select web activation and retained rollback afresh'
for invalid in \
  'del(.runtime.executable)' \
  '.runtime.executable=null' \
  '.runtime.executable="relative/omnigent"' \
  '.runtime.executable="/tmp/omnigent"' \
  '.runtime.executable += "/../omnigent"' \
  '.runtime.executable += "\n"' \
  '.runtime.executable += "-missing"' \
  '.managed_status.status="stopped"' \
  '.managed_service.server_url="http://127.0.0.1:9999"' \
  '.reasons=["serve_runtime_identity_mismatch"]' \
  '.status="failed"'; do
  jq "$invalid" "$TMP_ROOT/web.json" > "$readiness"
  if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail "invalid readiness accepted: $invalid"; fi
done
for malformed in '{bad json' '{} {}' '[]'; do
  printf '%s' "$malformed" > "$readiness"
  if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'malformed readiness accepted'; fi
done
# Oversized output must refuse even when its prefix is a complete valid report.
cat "$TMP_ROOT/web.json" > "$readiness"
head -c 131073 /dev/zero | tr '\000' ' ' >> "$readiness"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'oversized readiness accepted'; fi
cp "$TMP_ROOT/web.json" "$readiness"
chmod -x "$web"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'nonexecutable selection accepted'; fi
chmod +x "$web"
mv "$web" "$web.saved"
ln -s "$web.saved" "$web"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'symlink executable accepted'; fi
rm "$web"
mv "$web.saved" "$web"
cp "$OMNI_STATUS" "$TMP_ROOT/running.json"
jq '.status="stopped"' "$OMNI_STATUS" > "$TMP_ROOT/stopped.json"
cp "$TMP_ROOT/stopped.json" "$OMNI_STATUS"
rm "$OMNI_RESULT"
if "$OMNI" start codex > "$TMP_ROOT/error" 2>&1; then fail 'ready runtime bypassed stopped service'; fi
[ ! -e "$OMNI_RESULT" ] || fail 'stopped service launched selected executable'
cp "$TMP_ROOT/running.json" "$OMNI_STATUS"
cp "$TMP_ROOT/headless.json" "$readiness"
pass 'malformed, unsafe, inconsistent readiness and stopped service refuse'
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

# Git refuses to run when GIT_CONFIG_COUNT names an entry it cannot find, so
# the native environment receives the complete counted set or none of it.
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=fixture \
  GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/hooks "$OMNI" run codex 'git env'
jq -e '.environment.GIT_CONFIG_COUNT == "2" and
  .environment.GIT_CONFIG_KEY_0 == "credential.helper" and .environment.GIT_CONFIG_VALUE_0 == "fixture" and
  .environment.GIT_CONFIG_KEY_1 == "core.hooksPath" and .environment.GIT_CONFIG_VALUE_1 == "/hooks"' \
  "$OMNI_RESULT" >/dev/null || fail 'counted git configuration was not forwarded completely'
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/hooks "$OMNI" run codex 'git env'
jq -e '.environment | (has("GIT_CONFIG_COUNT") or has("GIT_CONFIG_KEY_0")) | not' "$OMNI_RESULT" >/dev/null \
  || fail 'incomplete git configuration reached the native environment'
env -u GIT_CONFIG_COUNT "$OMNI" run codex 'git env'
jq -e '.environment | has("GIT_CONFIG_COUNT") | not' "$OMNI_RESULT" >/dev/null || fail 'absent git configuration was invented'
pass 'native git configuration is forwarded as a complete counted set or not at all'

# A spawn-supplied binding records the verified session in its own task
# record and labels it; a record that names another generation is untouched.
binding_home="$TMP_ROOT/binding/state"
mkdir -p "$binding_home"
printf 'harness=codex\nomnigent=on\nspawn_gen=s1.1.1\n' > "$binding_home/bound.meta"
printf 'omnigent_session=%s\nomnigent_server=http://127.0.0.1:6767\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$binding_home/expected.meta"
cat "$binding_home/bound.meta" >> "$binding_home/expected.meta"
home_hash=$(printf '%0.s0123456789abcdef' 1 2 3 4)
reset_title
FM_OMNIGENT_RECORD_META="$binding_home/bound.meta" FM_OMNIGENT_RECORD_GEN=s1.1.1 FM_OMNIGENT_HOME_ID="$home_hash" \
  FM_OMNIGENT_TASK=bound FM_HOME="$TMP_ROOT/worker-home" FM_TASK_ID=bound "$OMNI" run codex 'bind' 2> "$TMP_ROOT/title-error"
wait_title
jq -e --arg home "$home_hash" '.labels["firstmate.home"] == $home and .labels["firstmate.task"] == "bound" and
  .labels["omnigent.wrapper"] == "codex-native-ui"' "$TMP_ROOT/serve/title.json" >/dev/null \
  || fail 'launch did not merge Firstmate identity labels'
attach_pid=$(sed -n 's/^omnigent_attach_pid=//p' "$binding_home/bound.meta")
attach_start=$(sed -n 's/^omnigent_attach_start=//p' "$binding_home/bound.meta")
[[ "$attach_pid" =~ ^[0-9]+$ ]] && [ -n "$attach_start" ] || fail 'launch did not bind its attach process identity'
sed '/^omnigent_attach_/d' "$binding_home/bound.meta" > "$binding_home/actual.meta"
cmp "$binding_home/expected.meta" "$binding_home/actual.meta" || fail 'verified session was not recorded exactly once'
printf 'harness=codex\nomnigent=on\nspawn_gen=s2.2.2\n' > "$binding_home/newer.meta"
cp "$binding_home/newer.meta" "$binding_home/newer.expected"
reset_title
FM_OMNIGENT_RECORD_META="$binding_home/newer.meta" FM_OMNIGENT_RECORD_GEN=s1.1.1 FM_OMNIGENT_HOME_ID="$home_hash" \
  FM_OMNIGENT_TASK=newer FM_HOME="$TMP_ROOT/worker-home" FM_TASK_ID=newer "$OMNI" run codex 'stale' 2> "$TMP_ROOT/title-error"
for _ in $(seq 1 80); do grep -q 'no longer names this launch' "$TMP_ROOT/title-error" && break; sleep 0.1; done
cmp "$binding_home/newer.expected" "$binding_home/newer.meta" || fail 'superseded launch overwrote a newer task record'
grep -q 'no longer names this launch' "$TMP_ROOT/title-error" || fail 'superseded launch did not report its skipped record'
reset_title
OMNI_TITLE_MODE=drop-labels FM_OMNIGENT_HOME_ID="$home_hash" FM_OMNIGENT_TASK=bound \
  FM_HOME="$TMP_ROOT/worker-home" FM_TASK_ID=bound "$OMNI" run codex 'labels' 2> "$TMP_ROOT/title-error"
for _ in $(seq 1 80); do grep -q 'Firstmate labels' "$TMP_ROOT/title-error" && break; sleep 0.1; done
grep -q 'did not confirm the Firstmate labels' "$TMP_ROOT/title-error" || fail 'unconfirmed labels were not reported'
pass 'launch records its verified session only in its own generation and confirms merged identity labels'

# Archive targets exactly the recorded session, never its worktree, and a
# failure only warns. Records without a binding send nothing.
rm -f "$TMP_ROOT/serve/archived.jsonl" "$TMP_ROOT/serve/requests.jsonl"
"$OMNI" archive --dry-run "$binding_home/bound.meta" > "$TMP_ROOT/out"
grep -qx 'would archive Omnigent session http://127.0.0.1:6767/v1/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$TMP_ROOT/out" || fail 'archive preview omitted its target'
[ ! -e "$TMP_ROOT/serve/requests.jsonl" ] || fail 'archive preview contacted the service'
"$OMNI" archive "$binding_home/bound.meta" > "$TMP_ROOT/out"
jq -se 'length == 1 and .[0].id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .[0].body == {archived:true}' \
  "$TMP_ROOT/serve/archived.jsonl" >/dev/null || fail 'archive did not PATCH exactly archived=true for the recorded session'
jq -se 'length == 1 and .[0].method == "PATCH" and
  .[0].url == "http://127.0.0.1:6767/v1/sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$TMP_ROOT/serve/requests.jsonl" >/dev/null || fail 'archive sent requests beyond its one PATCH'
rm -f "$TMP_ROOT/serve/requests.jsonl"
"$OMNI" archive "$binding_home/newer.meta" > "$TMP_ROOT/out"
[ ! -s "$TMP_ROOT/out" ] && [ ! -e "$TMP_ROOT/serve/requests.jsonl" ] || fail 'archive without a recorded session contacted the service'
rc=0
OMNI_ARCHIVE_MODE=http-error "$OMNI" archive "$binding_home/bound.meta" > "$TMP_ROOT/out" 2> "$TMP_ROOT/error" || rc=$?
[ "$rc" = 1 ] || fail 'failed archive did not exit 1'
grep -q 'warning: Omnigent archive' "$TMP_ROOT/error" || fail 'failed archive did not warn'
printf 'omnigent_session=../other\nomnigent_server=http://127.0.0.1:6767\n' > "$binding_home/forged.meta"
rm -f "$TMP_ROOT/serve/requests.jsonl"
if "$OMNI" archive "$binding_home/forged.meta" > "$TMP_ROOT/out" 2>&1; then fail 'malformed recorded session was archived'; fi
[ ! -e "$TMP_ROOT/serve/requests.jsonl" ] || fail 'malformed recorded session reached the service'
pass 'archive PATCHes only the recorded session and reports failure without blocking'

# The supervision probe maps a gone server or session to dead.
probe() { "$OMNI" probe "$binding_home/bound.meta"; }
[ "$(probe)" = alive ] || fail 'live session did not probe alive'
for gone in runner-gone failed archived missing; do
  [ "$(OMNI_SESSION_STATE=$gone probe)" = dead ] || fail "$gone session did not probe dead"
done
[ "$(OMNI_HEALTH=down probe)" = dead ] || fail 'unreachable server did not probe dead'
[ "$(OMNI_SESSION_STATE=server-error probe)" = unknown ] || fail 'unproven session reply was treated as a verdict'
[ "$("$OMNI" probe "$binding_home/newer.meta")" = unknown ] || fail 'record without a session was given a verdict'
(
. "$ROOT/bin/fm-backend.sh"
[ "$(OMNI_SESSION_STATE=runner-gone fm_backend_omnigent_agent_state alive "$binding_home/bound.meta")" = dead ] \
  || fail 'supervision view kept a wrapped worker with a gone session alive'
[ "$(fm_backend_omnigent_agent_state alive "$binding_home/bound.meta")" = alive ] || fail 'supervision view changed a live wrapped worker'
[ "$(OMNI_HEALTH=down fm_backend_omnigent_agent_state missing "$binding_home/bound.meta")" = missing ] \
  || fail 'supervision view rewrote a non-alive pane verdict'
[ "$(OMNI_HEALTH=down fm_backend_omnigent_agent_state alive "$binding_home/newer.meta")" = alive ] \
  || fail 'supervision view probed a record without a session'
)
pass 'a stopped server or gone session reads dead in the supervision view only when the pane reads alive'

if OMNI_HEALTH=down "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'unreachable server accepted'; fi
printf '{"status":"stopped","reason":"not_started"}\n' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'stopped server accepted'; fi
grep -q 'not_started' "$TMP_ROOT/error" || fail 'refusal omitted concrete service reason'
printf '{bad json' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'malformed service response accepted'; fi
if "$OMNI" check pi > "$TMP_ROOT/error" 2>&1; then fail 'unverified wrapped harness accepted'; fi
pass 'missing, unreachable, malformed service and unverified harness refuse'
fi

. "$ROOT/tests/fixtures.sh"
spawn_home="$TMP_ROOT/spawn-home"
spawn_project="$TMP_ROOT/project"
spawn_wt="$TMP_ROOT/worktree"
spawn_tools=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-tools")
fm_test_spawn_home "$spawn_home" codex
fm_git_worktree "$spawn_project" "$spawn_wt" omni-fixture
if [ "${1:-}" != --claude-accounts ]; then
fm_test_spawn_brief "$spawn_home" omni-test
printf '{"status":"stopped","reason":"not_started"}\n' > "$OMNI_STATUS"
if FM_OMNIGENT=on FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" \
  fm_test_run_spawn "$spawn_home" "$spawn_wt" "$spawn_tools" omni-test "$spawn_project" --mode no-mistakes --yolo off > "$TMP_ROOT/error" 2>&1; then
  fail 'spawn proceeded with a stopped Omnigent server'
fi
[ ! -e "$spawn_home/state/omni-test.meta" ] || fail 'refused spawn published task metadata'
grep -q not_started "$TMP_ROOT/error" || fail 'spawn did not report service refusal'
pass 'spawn refuses before endpoint publication when tracing is unavailable'
fi

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
if [ "${1:-}" != --claude-accounts ]; then
for kind in ship scout; do
  id="omni-$kind"
  fm_test_spawn_brief "$spawn_home" "$id"
  args=(--mode no-mistakes --yolo off)
  [ "$kind" != scout ] || args=(--scout)
  FM_OMNIGENT=on spawn "$id" "$spawn_project" "${args[@]}" --harness codex --model gpt-5.4 --effort high > "$TMP_ROOT/output" 2>&1 || fail "wrapped $kind spawn: $(cat "$TMP_ROOT/output")"
  execute_launch
  wait_title
  jq -e --arg expected "spawn-home · $id" '.title == $expected' "$TMP_ROOT/serve/title.json" >/dev/null || fail "$kind title lost dispatched home/task"
  jq -e '.argv[0] == "codex" and (.argv | index("gpt-5.4")) != null and
    (.argv | index("model_reasoning_effort=\"high\"")) != null and
    (.argv | any(.[]; startswith("notify="))) and
    .environment.FM_OMNIGENT == "on" and .environment.COMPACT_ADVISER_DISABLE == "1"' "$OMNI_RESULT" >/dev/null || fail "$kind lost dispatch, turn-end notification, or session propagation"
  grep -qx 'omnigent=on' "$spawn_home/state/$id.meta" || fail "$kind metadata lost wrapping"
  grep -qx 'omnigent_session=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$spawn_home/state/$id.meta" || fail "$kind did not record its session"
  expected_home=$(printf '%s' "$(cd "$spawn_home" && pwd -P)" | shasum -a 256 | awk '{print $1}')
  jq -e --arg home "$expected_home" --arg task "$id" '.labels["firstmate.home"] == $home and .labels["firstmate.task"] == $task' \
    "$TMP_ROOT/serve/title.json" >/dev/null || fail "$kind session lacks its home and task labels"
done
pass 'ship and scout pane launches preserve dispatch, notify, and explicit session environment, and record their labelled session'

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
wait_title
jq -e '.title == "secondmate · firstmate"' "$TMP_ROOT/serve/title.json" >/dev/null || fail 'spawned secondmate title lost its isolated primary identity'
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
fi

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

rm "$spawn_home/config/claude-account"
spawn_project="$spawn_home/user-home/workspace/guidex/app"
spawn_wt="$TMP_ROOT/guidex-worktree"
fm_git_worktree "$spawn_project" "$spawn_wt" guidex-fixture
mkdir -p "$spawn_home/projects" "$spawn_home/user-home/.claude_b"
ln -s "$spawn_project" "$spawn_home/projects/guidex_app"
cat > "$spawn_tools/claude" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\$*" = 'auth status' ]; then
  printf '%s|%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${USER-missing}" "\${LOGNAME-missing}" >> '$TMP_ROOT/claude-auth'
  [ ! -e '$TMP_ROOT/claude-signed-out' ]
else
  printf 'Claude Code fixture\n'
fi
SH
chmod +x "$spawn_tools/claude"
personal_project="$TMP_ROOT/personal-project"
fm_git_worktree "$personal_project" "$TMP_ROOT/personal-worktree" personal-fixture
for lane in guidex home; do
  if [ "$lane" = guidex ]; then
    project=projects/guidex_app
    spawn_wt="$TMP_ROOT/guidex-worktree"
    expected_root="$spawn_home/user-home/.claude_b"
  else
    project=$personal_project
    spawn_wt="$TMP_ROOT/personal-worktree"
    expected_root=''
  fi
  for kind in ship scout; do
    id="omni-$lane-$kind"
    fm_test_spawn_brief "$spawn_home" "$id"
    args=(--mode no-mistakes --yolo off)
    [ "$kind" != scout ] || args=(--scout)
    : > "$TMP_ROOT/serve/agent-kit.log"
    USER=fixture-user LOGNAME=fixture-user spawn "$id" "$project" "${args[@]}" --harness claude --model sonnet > "$TMP_ROOT/error" 2>&1 || fail "automatic Omnigent $lane $kind refused: $(cat "$TMP_ROOT/error")"
    [ "$(grep -cx 'observe serve status --json' "$TMP_ROOT/serve/agent-kit.log")" = 1 ] \
      || fail "$lane $kind spawn did not run exactly one spawn-side preflight"
    execute_launch
    wait_title
    if [ -n "$expected_root" ]; then
      jq -e --arg root "$expected_root" '.environment.CLAUDE_CONFIG_DIR == $root' "$OMNI_RESULT" >/dev/null || fail "$lane $kind lost the exact selected account at the daemon boundary"
    else
      jq -e '.environment | has("CLAUDE_CONFIG_DIR") | not' "$OMNI_RESULT" >/dev/null || fail "$lane $kind forwarded a personal account selector"
    fi
  done
done
jq 'del(.omnigent)' "$OMNI_STATUS" > "$TMP_ROOT/legacy-status.json"
cp "$OMNI_STATUS" "$TMP_ROOT/current-status.json"
cp "$TMP_ROOT/legacy-status.json" "$OMNI_STATUS"
fm_test_spawn_brief "$spawn_home" omni-legacy-guidex
spawn_wt="$TMP_ROOT/guidex-worktree"
if spawn omni-legacy-guidex projects/guidex_app --mode no-mistakes --yolo off --harness claude --model sonnet > "$TMP_ROOT/error" 2>&1; then fail 'legacy daemon spawn accepted GuideX'; fi
[ ! -e "$spawn_home/state/omni-legacy-guidex.meta" ] || fail 'legacy refusal published metadata'
cp "$TMP_ROOT/current-status.json" "$OMNI_STATUS"
cat > "$spawn_tools/quota-axi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
weekly=80 all=50
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then weekly=20 all=70; fi
jq -n --argjson weekly "$weekly" --argjson all "$all" '{schemaVersion:5,providers:[{provider:"claude",state:{status:"fresh"},windows:[{id:"model:fable",kind:"model",windowSeconds:604800,percentRemaining:$weekly}],quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:$all,runway:{status:"through_reset"}},{scope:"model:fable",status:"known",effectivePercentRemaining:$weekly,runway:{status:"through_reset"}}]}}]}'
SH
chmod +x "$spawn_tools/quota-axi"
fm_test_spawn_brief "$spawn_home" omni-floor
spawn omni-floor projects/guidex_app --mode no-mistakes --yolo off --harness claude --model fable --claude-floor '{"scope":"all_models","min_percent":60}' > "$TMP_ROOT/error" 2>&1 || fail "floor spawn refused: $(cat "$TMP_ROOT/error")"
execute_launch
wait_title
jq -e --arg root "$spawn_home/user-home/.claude_b" '.environment.CLAUDE_CONFIG_DIR == $root' "$OMNI_RESULT" >/dev/null || fail 'spawn spent personal allowance below its selected reserve'
sed -n 's/^claude_floor=//p' "$spawn_home/state/omni-floor.meta" | jq -e '. == [{scope:"all_models",min_percent:60}]' >/dev/null || fail 'spawn did not persist the selected floor'
grep -q "^$spawn_home/user-home/.claude_b|fixture-user|fixture-user$" "$TMP_ROOT/claude-auth" || fail 'GuideX sign-in check lost the selector or login environment'
touch "$TMP_ROOT/claude-signed-out"
fm_test_spawn_brief "$spawn_home" omni-signed-out
spawn_wt="$TMP_ROOT/guidex-worktree"
if spawn omni-signed-out projects/guidex_app --mode no-mistakes --yolo off --harness claude --model sonnet > "$TMP_ROOT/error" 2>&1; then fail 'signed-out automatic account accepted'; fi
[ ! -e "$spawn_home/state/omni-signed-out.meta" ] || fail 'signed-out account published metadata'
pass 'Omnigent ships and scouts forward exact automatic accounts and refuse signed-out logins before mutation'

CLAUDE_CONFIG_DIR="$TMP_ROOT/profile-link/" "$OMNI" run claude --model sonnet
jq -e --arg root "$TMP_ROOT/profile-link/" '.environment.CLAUDE_CONFIG_DIR == $root' "$OMNI_RESULT" >/dev/null || fail 'Omnigent rewrote an explicit selector'
pass 'Omnigent preserves the exact explicit Claude selector'
if [ "${1:-}" = --claude-accounts ]; then
  exit 0
fi

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
