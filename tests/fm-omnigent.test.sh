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
# The immutable installer selection and the measured runtime receipt must agree.
generation="sha256:$(printf '%064d' 1)"
source_commit=$(printf '%040d' 1)
jq -n --arg executable "$TMP_ROOT/runtime/bin/omnigent" --arg generation "$generation" --arg commit "$source_commit" '
  {schema_version:1,
   runtime:{executable:$executable,python:"/usr/bin/python3",generation:$generation,
            package_version:"0.16.0.dev0",source_commit:$commit,state_schema:1},
   endpoint:"http://127.0.0.1:6767",availability:"ready",
   allowed_client_environment:["OMNIGENT_AUTH_PROVIDER","OMNIGENT_CONFIG_HOME","OMNIGENT_DATA_DIR",
                               "OMNIGENT_LOCAL_SERVER_PORT","OMNIGENT_WEB_BASE_PATH"],
   client_environment:{OMNIGENT_CONFIG_HOME:"/private/fixture/config"},
   native_environment:{interface:"--env KEY=VALUE",max_entries:64,max_total_bytes:65536,ambient_forwarding:false},
   telemetry:{owner:"external",admission:"external_policy"}}
' > "$TMP_ROOT/contract.json"
verify_contract() {
  jq -L "$ROOT/bin" -se --arg executable "$TMP_ROOT/runtime/bin/omnigent" --arg generation "$generation" \
    --arg commit "$source_commit" --arg server 'http://127.0.0.1:6767' \
    --argjson environment '{"OMNIGENT_CONFIG_HOME":"/private/fixture/config"}' \
    'include "fm-omnigent-contract"; fm_omnigent_runtime_verified($executable; $generation; $commit; $server; $environment)' \
    "$1" >/dev/null 2>&1
}
verify_contract "$TMP_ROOT/contract.json" || fail 'valid measured runtime contract refused'
for invalid in \
  '.schema_version="1"' \
  '.schema_version=2' \
  '.availability="unverified"' \
  '.runtime.executable="/foreign/bin/omnigent"' \
  '.runtime.generation="sha256:" + ("f" * 64)' \
  '.runtime.source_commit=null' \
  '.runtime.source_commit=("f" * 40)' \
  '.runtime.state_schema=2' \
  '.runtime.python="relative/python"' \
  '.endpoint="http://127.0.0.1:6767/?token=secret"' \
  '.allowed_client_environment += ["OTEL_EXPORTER_OTLP_ENDPOINT"]' \
  '.client_environment.PATH="/foreign"' \
  '.client_environment.OMNIGENT_CONFIG_HOME="/foreign/config"' \
  '.native_environment.ambient_forwarding=true' \
  '.native_environment.interface="ambient"' \
  'del(.native_environment.interface)' \
  '.native_environment.max_entries=65' \
  '.telemetry.owner="omnigent"'; do
  jq "$invalid" "$TMP_ROOT/contract.json" > "$TMP_ROOT/invalid-contract.json"
  if verify_contract "$TMP_ROOT/invalid-contract.json"; then fail "invalid runtime contract accepted: $invalid"; fi
done
for malformed in '{bad json' '{} {}' '[]' 'null'; do
  printf '%s' "$malformed" > "$TMP_ROOT/invalid-contract.json"
  if verify_contract "$TMP_ROOT/invalid-contract.json"; then fail 'malformed runtime contract accepted'; fi
done
pass 'measured runtime, endpoint, environment, and schema match immutable selection'
refusal_category() {
  jq -L "$ROOT/bin" -ser 'include "fm-omnigent-contract"; fm_omnigent_error_category' "$1" 2>/dev/null
}
for category in invalid_endpoint endpoint_unavailable endpoint_mismatch auth_denied runtime_unverified runtime_mismatch; do
  jq -n --arg category "$category" '{schema_version:1,error:{category:$category,detail:"sensitive value"}}' \
    > "$TMP_ROOT/refusal.json"
  [ "$(refusal_category "$TMP_ROOT/refusal.json")" = "$category" ] || fail 'structured refusal lost its safe category'
  if verify_contract "$TMP_ROOT/refusal.json"; then fail 'refusal was accepted as a ready runtime'; fi
done
for invalid in '.schema_version=2' '.schema_version="1"' '.error.category="sensitive value"' '.error.category=null' '.error=[]'; do
  jq "$invalid" "$TMP_ROOT/refusal.json" > "$TMP_ROOT/invalid-refusal.json"
  if refusal_category "$TMP_ROOT/invalid-refusal.json" > "$TMP_ROOT/error"; then fail 'unknown or malformed refusal accepted'; fi
  [ ! -s "$TMP_ROOT/error" ] || fail 'malformed refusal leaked output'
done
pass 'only known structured refusal categories are exposed'
jq -n '{schema_version:1,harnesses:[
  {id:"codex-native",command:"codex",durable_custody:false,capabilities:{
    integration_mode:"native",elicitation:"unknown",resume:"unknown",effort:"unknown",
    model_family:"unknown",auth:"unknown",fork_history:"unknown",instruction_delivery:"unknown",
    subagents:true,interrupt:true,streaming:true,steering:null,live_queue:null,images:null,
    compaction:null,shell_tool_name:null,shell_tool_prompt:null}},
  {id:"claude-native",command:"claude",durable_custody:false,capabilities:{
    integration_mode:"native",elicitation:"unknown",resume:"unknown",effort:"unknown",
    model_family:"unknown",auth:"unknown",fork_history:"unknown",instruction_delivery:"unknown",
    subagents:true,interrupt:true,streaming:true,steering:false,live_queue:false,images:false,
    compaction:false,shell_tool_name:"bash",shell_tool_prompt:"shell"}}]}' > "$TMP_ROOT/harness-contract.json"
verify_harness() {
  jq -L "$ROOT/bin" -se --arg harness "$1" \
    'include "fm-omnigent-contract"; fm_omnigent_harness_verified($harness)' "$2" >/dev/null 2>&1
}
for harness in codex claude; do
  verify_harness "$harness" "$TMP_ROOT/harness-contract.json" || fail "callable $harness receipt refused"
done
for harness in codex-native codex-wrapper pi foreign; do
  if verify_harness "$harness" "$TMP_ROOT/harness-contract.json"; then fail "foreign wrapper command accepted: $harness"; fi
done
for invalid in \
  '.schema_version=2' \
  '.harnesses=[]' \
  '.harnesses={}' \
  '.harnesses += [.harnesses[0]]' \
  '.harnesses[1].id="codex-native"' \
  '.harnesses[0].command="codex-native"' \
  '.harnesses[0].command=["codex"]' \
  '.harnesses[0].durable_custody="false"' \
  '.harnesses[0].capabilities=[]' \
  '.harnesses[0].capabilities.streaming=null' \
  '.harnesses[0].capabilities.auth=false' \
  '.harnesses[0].capabilities.steering="unknown"' \
  '.harnesses[0].capabilities.shell_tool_name=false' \
  'del(.harnesses[0].capabilities.compaction)'; do
  jq "$invalid" "$TMP_ROOT/harness-contract.json" > "$TMP_ROOT/invalid-harness.json"
  if verify_harness codex "$TMP_ROOT/invalid-harness.json"; then fail "malformed or ambiguous harness receipt accepted: $invalid"; fi
done
for capability in steering live_queue images compaction; do
  for value in true false null; do
    jq --arg capability "$capability" --argjson value "$value" \
      '.harnesses[0].capabilities[$capability]=$value' "$TMP_ROOT/harness-contract.json" > "$TMP_ROOT/nullable-capability.json"
    verify_harness codex "$TMP_ROOT/nullable-capability.json" || fail "valid nullable $capability=$value refused"
  done
done
pass 'callable commands and typed capabilities refuse ambiguity and preserve unknown values'
selected_runtime=$(jq -c .runtime "$TMP_ROOT/contract.json")
verify_measured_runtime() {
  jq -L "$ROOT/bin" -se --argjson runtime "$selected_runtime" \
    --arg server 'http://127.0.0.1:6767' \
    --argjson environment '{"OMNIGENT_CONFIG_HOME":"/private/fixture/config"}' \
    'include "fm-omnigent-contract"; fm_omnigent_runtime_matches($runtime; $server; $environment)' \
    "$1" >/dev/null 2>&1
}
verify_measured_runtime "$TMP_ROOT/contract.json" || fail 'full measured runtime equality refused'
for invalid in \
  '.runtime.python="/foreign/python3"' \
  '.runtime.package_version="foreign"' \
  '.runtime.installer_generation="0123456789abcdef0123456789abcdef"'; do
  jq "$invalid" "$TMP_ROOT/contract.json" > "$TMP_ROOT/foreign-runtime.json"
  if verify_measured_runtime "$TMP_ROOT/foreign-runtime.json"; then fail "full runtime mismatch accepted: $invalid"; fi
done
pass 'the complete measured runtime object matches the independently selected receipt'
jq -n '{schema_version:1,owner:"pak",session_scope:"personal",work_session_policy:null,
  capture_enabled:false,collection_required:false,delivery_available:false,admission:"allow",reason:null,
  existing_sessions:"preserve",durable_acceptance:false,redactor_endpoint:null,
  client_environment:{OMNIGENT_TELEMETRY_ENABLED:"false",OMNIGENT_OTEL_CAPTURE_CONTENT:"false",
    OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION:"false",OTEL_METRICS_EXPORTER:"none",OTEL_LOGS_EXPORTER:"none"},
  loss:null,retry:{max_attempts:3,memory_queue_items:64,memory_queue_bytes:67108864}}' > "$TMP_ROOT/telemetry-off.json"
verify_telemetry() {
  jq -L "$ROOT/bin" -se 'include "fm-omnigent-contract"; fm_omnigent_telemetry_verified' "$1" >/dev/null 2>&1
}
verify_telemetry "$TMP_ROOT/telemetry-off.json" || fail 'excluded telemetry refused permitted new admission'
jq '.capture_enabled=true | .redactor_endpoint="http://127.0.0.1:5052" |
  .client_environment.OMNIGENT_TELEMETRY_ENABLED="true" | .client_environment.OMNIGENT_OTEL_CAPTURE_CONTENT="true" |
  .client_environment += {OTEL_EXPORTER_OTLP_PROTOCOL:"http/protobuf",
    OTEL_EXPORTER_OTLP_ENDPOINT:"http://127.0.0.1:5052",OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:"http://127.0.0.1:5052/v1/traces",
    OTEL_EXPORTER_OTLP_TRACES_HEADERS:"x-mlflow-experiment-id=7"} |
  .admission="allow_with_gap" | .reason="telemetry_gap"' "$TMP_ROOT/telemetry-off.json" > "$TMP_ROOT/telemetry-gap.json"
verify_telemetry "$TMP_ROOT/telemetry-gap.json" || fail 'personal trace gap blocked permitted admission'
jq '.collection_required=true | .admission="deny_new" | .reason="required_collection_unavailable"' \
  "$TMP_ROOT/telemetry-gap.json" > "$TMP_ROOT/telemetry-required.json"
verify_telemetry "$TMP_ROOT/telemetry-required.json" || fail 'required collection denial receipt refused'
jq '.delivery_available=true | .admission="allow" | .reason=null |
  .loss={accepted_batches:0,delivered_batches:0,dropped_batches:0,queue_rejected_batches:0,retry_attempts:0}' \
  "$TMP_ROOT/telemetry-required.json" > "$TMP_ROOT/telemetry-ready.json"
verify_telemetry "$TMP_ROOT/telemetry-ready.json" || fail 'available required collection receipt refused'
for invalid in \
  '.schema_version="1"' \
  '.owner="omnigent"' \
  '.session_scope="work"' \
  '.work_session_policy="exclude"' \
  '.capture_enabled="false"' \
  '.admission="allow"' \
  '.reason=null' \
  '.existing_sessions="terminate"' \
  '.durable_acceptance=true' \
  '.redactor_endpoint="http://127.0.0.1:5051"' \
  '.client_environment.OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:5051"' \
  '.client_environment.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="https://external.example/v1/traces"' \
  '.client_environment.OMNIGENT_DATA_DIR="/foreign"' \
  '.client_environment.OTEL_RESOURCE_ATTRIBUTES="raw-content"' \
  '.client_environment.OMNIGENT_TELEMETRY_ENABLED="false"' \
  '.client_environment.OMNIGENT_OTEL_CAPTURE_CONTENT=true' \
  '.client_environment.OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION="true"' \
  '.client_environment.OTEL_METRICS_EXPORTER="otlp"' \
  '.client_environment.OTEL_EXPORTER_OTLP_PROTOCOL="grpc"' \
  '.client_environment.OTEL_EXPORTER_OTLP_TRACES_HEADERS="x-mlflow-experiment-id=arbitrary"' \
  '.loss={dropped_items:0}' \
  '.loss="unknown"' \
  '.retry.max_attempts=0'; do
  jq "$invalid" "$TMP_ROOT/telemetry-required.json" > "$TMP_ROOT/invalid-telemetry.json"
  if verify_telemetry "$TMP_ROOT/invalid-telemetry.json"; then fail "unsafe or inconsistent telemetry accepted: $invalid"; fi
done
jq '.client_environment.OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:5052"' \
  "$TMP_ROOT/telemetry-off.json" > "$TMP_ROOT/invalid-telemetry.json"
if verify_telemetry "$TMP_ROOT/invalid-telemetry.json"; then fail 'excluded work retained an exporter destination'; fi
for scope in client employer bigspark-kiro; do
  jq --arg scope "$scope" '.session_scope=$scope | .work_session_policy="exclude"' \
    "$TMP_ROOT/telemetry-off.json" > "$TMP_ROOT/scoped-policy.json"
  verify_telemetry "$TMP_ROOT/scoped-policy.json" || fail "$scope exclusion refused"
  jq '.collection_required=true | .admission="deny_new" | .reason="required_collection_unavailable"' \
    "$TMP_ROOT/scoped-policy.json" > "$TMP_ROOT/invalid-telemetry.json"
  if verify_telemetry "$TMP_ROOT/invalid-telemetry.json"; then fail "$scope required collection accepted excluded capture"; fi
  jq --arg scope "$scope" '.session_scope=$scope | .work_session_policy="tag"' \
    "$TMP_ROOT/telemetry-gap.json" > "$TMP_ROOT/scoped-policy.json"
  verify_telemetry "$TMP_ROOT/scoped-policy.json" || fail "$scope redacted tagging refused"
done
jq '.redactor_endpoint="http://127.0.0.1:6152" |
  .client_environment.OTEL_EXPORTER_OTLP_ENDPOINT=.redactor_endpoint |
  .client_environment.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=(.redactor_endpoint + "/v1/traces")' \
  "$TMP_ROOT/telemetry-gap.json" > "$TMP_ROOT/custom-redactor.json"
verify_telemetry "$TMP_ROOT/custom-redactor.json" || fail 'explicit configured temporary redactor port refused'
for invalid in '.loss.dropped_batches=-1' '.loss.accepted_batches=true' '.loss.retry_attempts=0.5' 'del(.loss.delivered_batches)'; do
  jq "$invalid" "$TMP_ROOT/telemetry-ready.json" > "$TMP_ROOT/invalid-telemetry.json"
  if verify_telemetry "$TMP_ROOT/invalid-telemetry.json"; then fail "invalid loss evidence accepted: $invalid"; fi
done
pass 'telemetry admission distinguishes gaps and required denial while preserving existing custody'
jq -n --argjson runtime "$selected_runtime" --arg environment "$TMP_ROOT/runtime" \
  '{schema_version:1,owner:"pak",runtime:$runtime,
    installer:{component:"omnigent",generation:"0123456789abcdef0123456789abcdef",
      environment:$environment,manifest_sha256:("a" * 64)},endpoint:"http://127.0.0.1:6767",
    client_environment:{OMNIGENT_CONFIG_HOME:"/private/fixture/config",OMNIGENT_DATA_DIR:"/private/fixture/data",
      OMNIGENT_LOCAL_SERVER_PORT:"6767"}}' > "$TMP_ROOT/selector.json"
verify_selector() {
  jq -L "$ROOT/bin" -se 'include "fm-omnigent-contract"; fm_omnigent_selector_verified' "$1" >/dev/null 2>&1
}
verify_selector "$TMP_ROOT/selector.json" || fail 'explicit installer-selected runtime receipt refused'
for invalid in \
  '.owner="omnigent"' \
  '.installer.environment={}' \
  '.installer.environment="relative/environment"' \
  '.installer.component="collector"' \
  '.installer.generation=.runtime.generation' \
  '.runtime.generation=.installer.generation' \
  '.installer.manifest_sha256=null' \
  '.runtime.executable="/foreign/omnigent"' \
  '.endpoint="http://127.0.0.1:9999"' \
  '.client_environment.OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:5051"' \
  '.client_environment.OMNIGENT_LOCAL_SERVER_PORT="0"' \
  '.client_environment.OMNIGENT_DATA_DIR="relative/data"'; do
  jq "$invalid" "$TMP_ROOT/selector.json" > "$TMP_ROOT/invalid-selector.json"
  if verify_selector "$TMP_ROOT/invalid-selector.json"; then fail "malformed or inconsistent selector accepted: $invalid"; fi
done
pass 'installer identity and exact owner environment refuse malformed or inconsistent selection'

jq -n --arg workspace "$TMP_ROOT" '
  def process($pid): {pid:$pid,started_at:1000,pid_ns:"none",boot_id:null};
  {schema_version:1,session_id:"session-1",runner_id:"runner-1",harness:"codex-native",
   owner_generation:"owner-1",host_id:"host-1",endpoint:"http://127.0.0.1:6767",workspace:$workspace,
   config_digest:("a" * 64),environment_digest:("b" * 64),owner:process(101),native:process(102),
   terminal:{name:"codex/main",session_key:"terminal-1",socket:"/tmp/fixture-native.sock",device:1,inode:2,
     tmux:process(103),pane:process(104)}}' > "$TMP_ROOT/binding.json"
verify_binding() {
  jq -L "$ROOT/bin" -se --arg workspace "$TMP_ROOT" --arg endpoint http://127.0.0.1:6767 \
    'include "fm-omnigent-contract"; fm_omnigent_binding_verified($workspace; $endpoint)' "$1" >/dev/null 2>&1
}
verify_binding "$TMP_ROOT/binding.json" || fail 'valid exact native binding refused'
for invalid in '.schema_version=2' '.extra=true' '.harness="claude-native"' '.session_id=""' \
  '.workspace="/foreign"' '.endpoint="http://127.0.0.1:6768"' '.owner.pid=0' '.owner.started_at=null' \
  '.config_digest="bad"' '.terminal.name="codex/other"' '.terminal.socket="relative"' \
  '.terminal.inode=-1' '.native.pid=true' 'del(.owner.boot_id)'; do
  jq "$invalid" "$TMP_ROOT/binding.json" > "$TMP_ROOT/invalid-binding.json"
  if verify_binding "$TMP_ROOT/invalid-binding.json"; then fail "unsafe native binding accepted: $invalid"; fi
done
pass 'public binding pins schema, task scope, native process and terminal identities'
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
OMNI_STATUS="$TMP_ROOT/serve/launch-contract.json"
OMNI_RESULT="$TMP_ROOT/serve/result.json"
"$OMNI" check codex
if grep -qx 'observe serve status --json' "$TMP_ROOT/serve/calls.log"; then fail 'aggregate trace health still gates launch'; fi
"$OMNI" start --dry-run codex > "$TMP_ROOT/gap-preview.json"
jq -e '.telemetry.admission == "allow_with_gap" and .telemetry.delivery_available == false and
  .telemetry.loss == null and .runtime.generation != .installer_generation' "$TMP_ROOT/gap-preview.json" >/dev/null \
  || fail 'cold-start preview lost independent telemetry degradation or runtime identity'
pass 'trace outage does not gate verified runtime admission and loss remains unknown'

# Both owners are queried afresh for activation and retained-runtime rollback.
cp "$TMP_ROOT/serve/selector.json" "$TMP_ROOT/headless-selector.json"
cp "$OMNI_STATUS" "$TMP_ROOT/headless-receipt.json"
web="$TMP_ROOT/serve/generations/web/runtime/bin/omnigent"
mkdir -p "$(dirname "$web")"
cp "$TMP_ROOT/serve/runtime/bin/omnigent" "$web"
jq --arg executable "$web" '.runtime.executable=$executable | .runtime.generation=("sha256:" + ("e" * 64))' \
  "$TMP_ROOT/headless-receipt.json" > "$TMP_ROOT/web-receipt.json"
jq --arg environment "$TMP_ROOT/serve/generations/web/runtime" \
  '{schema_version:1,owner:"pak",runtime,endpoint,client_environment,
    installer:{component:"omnigent",generation:("f" * 32),environment:$environment,manifest_sha256:("d" * 64)}}' \
  "$TMP_ROOT/web-receipt.json" > "$TMP_ROOT/web-selector.json"
for selected in web headless web; do
  cp "$TMP_ROOT/$selected-selector.json" "$TMP_ROOT/serve/selector.json"
  cp "$TMP_ROOT/$selected-receipt.json" "$OMNI_STATUS"
  expected=$(jq -r .runtime.executable "$OMNI_STATUS")
  for harness in claude codex kiro agy; do
    "$OMNI" run --dry-run "$harness" > "$TMP_ROOT/preview.json"
    jq -e --arg expected "$expected" '.executable == $expected' "$TMP_ROOT/preview.json" >/dev/null || fail 'preview cached a generation'
  done
  "$OMNI" start codex
  jq -e --arg expected "$expected" '.executable == $expected' "$OMNI_RESULT" >/dev/null || fail 'launch used a stale selected executable'
done
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
pass 'fresh explicit selection preserves activation and retained-runtime rollback'

if OMNI_NO_ENV=1 "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'native environment capability was not checked'; fi
grep -q 'native --env interface' "$TMP_ROOT/error" || fail 'capability refusal lost its actionable reason'
for invalid in '.runtime.generation=("sha256:" + ("f" * 64))' '.runtime.python="/foreign/python"' \
  '.client_environment.OMNIGENT_CONFIG_HOME="/foreign/config"' '.harnesses += [.harnesses[1]]'; do
  jq "$invalid" "$TMP_ROOT/headless-receipt.json" > "$OMNI_STATUS"
  if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail "launch accepted mismatched public receipt: $invalid"; fi
done
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
cp "$TMP_ROOT/serve/telemetry.json" "$TMP_ROOT/permitted-policy.json"
jq '.collection_required=true | .admission="deny_new" | .reason="required_collection_unavailable"' \
  "$TMP_ROOT/permitted-policy.json" > "$TMP_ROOT/serve/telemetry.json"
rm -f "$OMNI_RESULT"
if "$OMNI" start codex > "$TMP_ROOT/error" 2>&1; then fail 'required collection admitted a new session without delivery'; fi
grep -q 'required_collection_unavailable.*existing sessions preserved' "$TMP_ROOT/error" || fail 'admission denial lost its policy/custody distinction'
[ ! -e "$OMNI_RESULT" ] || fail 'denied policy started a native session'
cp "$TMP_ROOT/permitted-policy.json" "$TMP_ROOT/serve/telemetry.json"
pass 'mismatched identity, missing wrapper capability, and required collection refuse before native launch'

(
  binding_home="$TMP_ROOT/binding-home"
  mkdir -p "$binding_home/state" "$binding_home/data/bound" "$binding_home/config"
  printf 'window=fmses:fm-bound\nendpoint_task_id=bound\nbackend=tmux\nharness=codex\nomnigent=on\nworktree=%s\nproject=%s\n' \
    "$TMP_ROOT" "$TMP_ROOT" > "$binding_home/state/bound.meta"
  cp "$TMP_ROOT/binding.json" "$TMP_ROOT/serve/binding.json"
  jq '.harnesses |= map(if .command == "codex" then .durable_custody=true else . end)' \
    "$OMNI_STATUS" > "$TMP_ROOT/custody.json"
  cp "$TMP_ROOT/custody.json" "$OMNI_STATUS"
  binding_run() {
    (cd "$TMP_ROOT"; FM_HOME="$binding_home" FM_TASK_ID=bound "$OMNI" "$1" \
      --task-meta "$binding_home/state/bound.meta" --task-data "$binding_home/data/bound" codex "${@:2}")
  }
  binding_run run 'initial synthetic prompt' || fail 'binding launch refused a valid task'
  stored="$binding_home/data/bound/omnigent-binding.json"
  cmp -s <(jq -S . "$stored") <(jq -S . "$TMP_ROOT/binding.json") || fail 'launch did not store the exact owner binding'
  [ "$(wc -l < "$TMP_ROOT/serve/native-launches.log" | tr -d ' ')" = 1 ] || fail 'binding launch created more than one native session'
  [ "$(wc -l < "$TMP_ROOT/serve/attachments.log" | tr -d ' ')" = 1 ] || fail 'initial binding did not attach once'
  cp "$stored" "$TMP_ROOT/stored-before.json"
  jq '.collection_required=true | .admission="deny_new" | .reason="required_collection_unavailable"' \
    "$TMP_ROOT/permitted-policy.json" > "$TMP_ROOT/serve/telemetry.json"
  binding_run verify-binding > "$TMP_ROOT/verified-binding.json" || fail 'existing verification used new-admission policy'
  cmp -s <(jq -S . "$TMP_ROOT/verified-binding.json") <(jq -S . "$stored") || fail 'public verification changed the bound owner'
  binding_run reattach || fail 'existing attachment used new-admission policy'
  cmp -s "$stored" "$TMP_ROOT/stored-before.json" || fail 'reattachment changed the owner binding'
  [ "$(wc -l < "$TMP_ROOT/serve/native-launches.log" | tr -d ' ')" = 1 ] || fail 'reattachment launched a duplicate native session'
  jq -e 'all(.[]; . != "--prompt" and . != "--model" and . != "initial synthetic prompt")' \
    "$TMP_ROOT/serve/attachments.log" >/dev/null || fail 'reattachment repeated native launch options'
  if binding_run run 'duplicate prompt' > "$TMP_ROOT/error" 2>&1; then fail 'existing association admitted another native session'; fi
  if OMNI_BINDING_SWAP=1 binding_run verify-binding > "$TMP_ROOT/error" 2>&1; then fail 'changed owner binding accepted'; fi
  for category in stale_attachment foreign_socket scope_mismatch binding_mismatch; do
    if OMNI_BINDING_ERROR="$category" binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'unsafe owner refusal accepted'; fi
    assert_contains "$(cat "$TMP_ROOT/error")" "$category" 'safe binding refusal category lost'
    assert_not_contains "$(cat "$TMP_ROOT/error")" synthetic-private 'owner refusal leaked raw details'
  done
  mkdir -p "$binding_home/data/duplicate"
  cp "$binding_home/state/bound.meta" "$binding_home/state/duplicate.meta"
  cp "$stored" "$binding_home/data/duplicate/omnigent-binding.json"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'another task adopted the same native binding'; fi
  rm "$binding_home/state/duplicate.meta"
  mv "$stored" "$TMP_ROOT/stored-good.json"
  ln -s "$TMP_ROOT/stored-good.json" "$stored"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'symlink task binding accepted'; fi
  rm "$stored"
  cp "$TMP_ROOT/stored-good.json" "$stored"
  chmod 644 "$stored"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'public task binding permissions accepted'; fi
  chmod 600 "$stored"
  ln "$stored" "$TMP_ROOT/binding-hardlink"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'hardlinked task binding accepted'; fi
  rm "$TMP_ROOT/binding-hardlink"
  python3 - "$stored" <<'PY_BOUND'
import sys
with open(sys.argv[1], 'w') as stream:
    stream.write(' ' * 65537)
PY_BOUND
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'oversized task binding accepted'; fi
  cp "$TMP_ROOT/stored-good.json" "$stored"
  python3 - "$stored" <<'PY_BOUND'
import sys
with open(sys.argv[1], 'a') as stream:
    stream.write('\n' * 65537)
PY_BOUND
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'newline-padded oversized binding accepted'; fi
  printf '{}\n' > "$stored"
  chmod 600 "$stored"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'malformed task binding accepted'; fi
  rm "$stored"
  if binding_run reattach > "$TMP_ROOT/error" 2>&1; then fail 'legacy task without a binding guessed a native identity'; fi
  [ "$(wc -l < "$TMP_ROOT/serve/native-launches.log" | tr -d ' ')" = 1 ] || fail 'refusals launched another native session'
  cp "$TMP_ROOT/permitted-policy.json" "$TMP_ROOT/serve/telemetry.json"
  if OMNI_BINDING_ERROR=launch_unavailable binding_run run 'interrupted launch' > "$TMP_ROOT/error" 2>&1; then fail 'failed owner creation accepted'; fi
  [ -f "$stored" ] && [ ! -s "$stored" ] || fail 'failed creation lost its duplicate-prevention reservation'
  if binding_run run 'retry duplicate' > "$TMP_ROOT/error" 2>&1; then fail 'uncertain creation retried without reconciliation'; fi
  [ "$(wc -l < "$TMP_ROOT/serve/native-launches.log" | tr -d ' ')" = 1 ] || fail 'uncertain creation admitted a duplicate native session'
) || fail 'strict task binding and reattachment contract failed'
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
pass 'one public task binding reattaches unchanged during required collection denial; duplicate and unsafe adoption refuse'

mv "$TMP_ROOT/serve/runtime/bin/omnigent" "$TMP_ROOT/serve/runtime/bin/selected-cli"
ln -s selected-cli "$TMP_ROOT/serve/runtime/bin/omnigent"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'symlink selected executable accepted'; fi
grep -q 'symlink in selected executable path' "$TMP_ROOT/error" || fail 'symlink refusal lost its safe reason'
rm "$TMP_ROOT/serve/runtime/bin/omnigent"
mv "$TMP_ROOT/serve/runtime/bin/selected-cli" "$TMP_ROOT/serve/runtime/bin/omnigent"
jq -n '{padding:("x" * 131073)}' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'oversized public receipt accepted'; fi
grep -q 'exceeds 128 KiB' "$TMP_ROOT/error" || fail 'public receipt size was not bounded'
for category in auth_denied runtime_unverified runtime_mismatch endpoint_mismatch invalid_endpoint; do
  jq -n --arg category "$category" \
    '{schema_version:1,error:{category:$category,detail:"synthetic-private-detail"}}' > "$OMNI_STATUS"
  rm -f "$OMNI_RESULT"
  if "$OMNI" start codex > "$TMP_ROOT/error" 2>&1; then fail "public refusal accepted: $category"; fi
  grep -q "$category" "$TMP_ROOT/error" || fail 'public refusal lost its known category'
  assert_not_contains "$(cat "$TMP_ROOT/error")" synthetic-private-detail 'public refusal leaked raw owner diagnostics'
  [ ! -e "$OMNI_RESULT" ] || fail 'public refusal launched a native session'
done
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
pass 'symlink and oversized receipts refuse; authentication and runtime errors retain only safe categories'

jq '.session_scope="client" | .work_session_policy="exclude"' "$TMP_ROOT/telemetry-off.json" > "$TMP_ROOT/serve/telemetry.json"
AGENT_KIT_OBSERVATION_DIR="$TMP_ROOT/explicit-observation" OTEL_EXPORTER_OTLP_ENDPOINT=https://raw.invalid \
  OTEL_RESOURCE_ATTRIBUTES='private=synthetic' "$OMNI" run codex 'excluded session'
jq -e --arg root "$TMP_ROOT/explicit-observation" '
  .environment.AGENT_KIT_OBSERVATION_DIR == $root and .environment.OMNIGENT_TELEMETRY_ENABLED == "false" and
  .environment.OMNIGENT_OTEL_CAPTURE_CONTENT == "false" and .environment.OTEL_EXPORTER_OTLP_ENDPOINT == "" and
  .client_telemetry == "false" and .client_endpoint == null and .client_resource_attributes == null' \
  "$OMNI_RESULT" >/dev/null || fail 'excluded capture leaked ambient export settings or lost the explicit owner root'
cp "$TMP_ROOT/permitted-policy.json" "$TMP_ROOT/serve/telemetry.json"
pass 'excluded work clears stale export settings and explicitly preserves owner root configuration'
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
printf '{"schema_version":1,"error":{"category":"endpoint_unavailable"}}\n' > "$OMNI_STATUS"
if "$OMNI" check codex > "$TMP_ROOT/error" 2>&1; then fail 'stopped server accepted'; fi
grep -q 'endpoint_unavailable' "$TMP_ROOT/error" || fail 'refusal omitted concrete service category'
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
printf '{"schema_version":1,"error":{"category":"endpoint_unavailable"}}\n' > "$OMNI_STATUS"
if FM_OMNIGENT=on FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log" \
  fm_test_run_spawn "$spawn_home" "$spawn_wt" "$spawn_tools" omni-test "$spawn_project" --mode no-mistakes --yolo off > "$TMP_ROOT/error" 2>&1; then
  fail 'spawn proceeded with a stopped Omnigent server'
fi
[ ! -e "$spawn_home/state/omni-test.meta" ] || fail 'refused spawn published task metadata'
grep -q endpoint_unavailable "$TMP_ROOT/error" || fail 'spawn did not report service refusal'
pass 'spawn refuses before endpoint publication when Omnigent is unavailable'

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
printf '{"schema_version":1,"error":{"category":"endpoint_unavailable"}}\n' > "$OMNI_STATUS"
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
  '.endpoint="https://external.example"' \
  '.client_environment={}' \
  '.client_environment.PATH="/tmp/override"' \
  '.client_environment.OTEL_BAD="line\nbreak"' \
  '.runtime.executable="relative/omnigent"'; do
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
