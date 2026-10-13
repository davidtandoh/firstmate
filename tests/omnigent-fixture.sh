#!/usr/bin/env bash
# Isolated owner/CLI contract double shared by local and SSH launch tests.
# The CLI records argv and the explicit native environment without model calls.
set -euo pipefail
fm_test_omnigent_service() { # <service-root> <tool-dir>
  local service=$1 tools=$2
  mkdir -p "$service/runtime/bin" "$tools"
  jq -n --arg executable "$service/runtime/bin/omnigent" --arg config "$service/config" --arg data "$service/data" '
    def caps: {integration_mode:"native",elicitation:"unknown",resume:"unknown",effort:"unknown",
      model_family:"unknown",auth:"unknown",fork_history:"unknown",instruction_delivery:"unknown",
      subagents:true,interrupt:true,streaming:true,steering:null,live_queue:null,images:null,
      compaction:null,shell_tool_name:null,shell_tool_prompt:null};
    {schema_version:1,runtime:{executable:$executable,python:"/usr/bin/python3",generation:("sha256:" + ("a" * 64)),
      package_version:"fixture",source_commit:("b" * 40),state_schema:1},endpoint:"http://127.0.0.1:6767",availability:"ready",
      allowed_client_environment:["OMNIGENT_AUTH_PROVIDER","OMNIGENT_CONFIG_HOME","OMNIGENT_DATA_DIR",
        "OMNIGENT_LOCAL_SERVER_PORT","OMNIGENT_WEB_BASE_PATH"],
      client_environment:{OMNIGENT_CONFIG_HOME:$config,OMNIGENT_DATA_DIR:$data,OMNIGENT_LOCAL_SERVER_PORT:"6767"},
      native_environment:{interface:"--env KEY=VALUE",max_entries:64,max_total_bytes:65536,ambient_forwarding:false},
      harnesses:[{id:"claude-native",command:"claude",capabilities:caps,durable_custody:false},
        {id:"codex-native",command:"codex",capabilities:caps,durable_custody:false},
        {id:"fixture-kiro",command:"kiro",capabilities:caps,durable_custody:false},
        {id:"fixture-agy",command:"agy",capabilities:caps,durable_custody:false}],
      telemetry:{owner:"external",admission:"external_policy"}}' > "$service/launch-contract.json"
  jq --arg environment "$service/runtime" '
    {schema_version:1,owner:"pak",runtime,endpoint,client_environment,
      installer:{component:"omnigent",generation:("c" * 32),environment:$environment,manifest_sha256:("d" * 64)}}' \
    "$service/launch-contract.json" > "$service/selector.json"
  jq -n '{schema_version:1,owner:"pak",session_scope:"personal",work_session_policy:null,
    capture_enabled:true,collection_required:false,delivery_available:false,admission:"allow_with_gap",reason:"telemetry_gap",
    existing_sessions:"preserve",durable_acceptance:false,redactor_endpoint:"http://127.0.0.1:5052",
    client_environment:{OMNIGENT_TELEMETRY_ENABLED:"true",OMNIGENT_OTEL_CAPTURE_CONTENT:"true",
      OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION:"false",OTEL_METRICS_EXPORTER:"none",OTEL_LOGS_EXPORTER:"none",
      OTEL_EXPORTER_OTLP_PROTOCOL:"http/protobuf",OTEL_EXPORTER_OTLP_ENDPOINT:"http://127.0.0.1:5052",
      OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:"http://127.0.0.1:5052/v1/traces",
      OTEL_EXPORTER_OTLP_TRACES_HEADERS:"x-mlflow-experiment-id=7"},
    loss:null,retry:{max_attempts:3,memory_queue_items:64,memory_queue_bytes:67108864}}' > "$service/telemetry.json"
  printf '{"status":"degraded","reason":"trace_delivery_unavailable"}\n' > "$service/status.json"
  cat > "$tools/agent-kit" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> '$service/calls.log'
case "\$*" in
  'observe serve runtime-receipt --json') cat '$service/selector.json' ;;
  'observe serve telemetry --json') cat '$service/telemetry.json' ;;
  'observe serve status --json') cat '$service/status.json'; exit 2 ;;
  *) exit 2 ;;
esac
SHIM
  cat > "$tools/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[ "${OMNI_HEALTH:-ok}" = ok ] || exit 7
printf '{"status":"ok"}\n'
SHIM
  cat > "$service/runtime/bin/omnigent" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *--help) [ "${OMNI_NO_ENV:-0}" = 1 ] || printf '  --env KEY=VALUE\n'; exit 0 ;;
  'runtime launch-contract --server http://127.0.0.1:6767 --json')
    if [ "${OMNI_HEALTH:-ok}" != ok ]; then
      printf '{"schema_version":1,"error":{"category":"endpoint_unavailable"}}\n'; exit 1
    fi
    service=$(dirname "$OMNIGENT_CONFIG_HOME")
    cat "$service/launch-contract.json"
    jq -e '.availability == "ready"' "$service/launch-contract.json" >/dev/null 2>&1 || exit 1
    exit 0 ;;
esac
python3 - "$0" "$@" <<'PY'
import json, os, pathlib, subprocess, sys
service = pathlib.Path(os.environ['OMNIGENT_CONFIG_HOME']).parent
args = sys.argv[2:]
environment = {}
for index, value in enumerate(args[:-1]):
    if value == '--env':
        name, text = args[index + 1].split('=', 1)
        environment[name] = text
with (service / 'result.json').open('w') as output:
    json.dump({'executable': sys.argv[1], 'argv': args, 'environment': environment,
               'client_encoding': subprocess.check_output(['locale', 'charmap'], text=True).strip(),
               'config_home': os.environ.get('OMNIGENT_CONFIG_HOME'),
               'client_telemetry': os.environ.get('OMNIGENT_TELEMETRY_ENABLED'),
               'client_endpoint': os.environ.get('OTEL_EXPORTER_OTLP_ENDPOINT'),
               'client_resource_attributes': os.environ.get('OTEL_RESOURCE_ATTRIBUTES')}, output)
PY
SHIM
  chmod +x "$tools/agent-kit" "$tools/curl" "$service/runtime/bin/omnigent"
}
