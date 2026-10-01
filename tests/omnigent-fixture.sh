#!/usr/bin/env bash
# Isolated status/CLI contract double shared by local and SSH launch tests.
# The CLI records argv and the explicit native environment without model calls.
set -euo pipefail
fm_test_omnigent_service() { # <service-root> <tool-dir>
  local service=$1 tools=$2
  mkdir -p "$service/runtime/bin" "$tools"
  jq -n --arg state "$service/serve.json" --arg config "$service/config" \
    '{status:"running",server_url:"http://127.0.0.1:6767",state_file:$state,client_environment:{OMNIGENT_CONFIG_HOME:$config}}' > "$service/status.json"
  cat > "$tools/agent-kit" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
[ "\$*" = 'observe serve status --json' ] || exit 2
cat '$service/status.json'
jq -e '.status == "running"' '$service/status.json' >/dev/null 2>&1 || exit 2
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
case "$*" in *--help) printf '  --env KEY=VALUE\n'; exit 0 ;; esac
python3 - "$0" "$@" <<'PY'
import json, os, pathlib, subprocess, sys
service = pathlib.Path(sys.argv[1]).parents[2]
args = sys.argv[2:]
environment = {}
for index, value in enumerate(args[:-1]):
    if value == '--env':
        name, text = args[index + 1].split('=', 1)
        environment[name] = text
with (service / 'result.json').open('w') as output:
    json.dump({'argv': args, 'environment': environment,
               'client_encoding': subprocess.check_output(['locale', 'charmap'], text=True).strip(),
               'config_home': os.environ.get('OMNIGENT_CONFIG_HOME')}, output)
PY
SHIM
  chmod +x "$tools/agent-kit" "$tools/curl" "$service/runtime/bin/omnigent"
}
