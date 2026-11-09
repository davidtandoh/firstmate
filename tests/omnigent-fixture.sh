#!/usr/bin/env bash
# Isolated status/CLI contract double shared by local and SSH launch tests.
# The CLI records argv and the explicit native environment without model calls.
set -euo pipefail
fm_test_omnigent_service() { # <service-root> <tool-dir>
  local service=$1 tool_dir=$2
  mkdir -p "$service/runtime/bin" "$tool_dir"
  jq -n --arg state "$service/serve.json" --arg config "$service/config" \
    '{omnigent:{repository:"https://github.com/davidtandoh/omnigent.git",commit:"bea4e262f08245deabed86a9b1eb4cafbcac1423"},status:"running",server_url:"http://127.0.0.1:6767",state_file:$state,client_environment:{OMNIGENT_CONFIG_HOME:$config}}' > "$service/status.json"
  jq -n --arg executable "$service/runtime/bin/omnigent" \
    '{schema_version:"1",status:"unavailable",reasons:["serve_setup_headless_only","serve_web_assets_missing"],
      managed_status:{status:"running"},managed_service:{server_url:"http://127.0.0.1:6767"},
      runtime:{executable:$executable}}' > "$service/readiness.json"
  cat > "$tool_dir/agent-kit" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> '$service/agent-kit.log'
if [ "\$*" = 'observe serve status --readiness --json' ]; then
  if [ "\${OMNI_DELAY_STAGE:-}" = readiness ]; then sleep "\${OMNI_STAGE_DELAY:-0}"; fi
  cat '$service/readiness.json'
  jq -e '.status == "ready" or .status == "unavailable"' '$service/readiness.json' >/dev/null 2>&1 || exit 2
  exit 0
fi
[ "\$*" = 'observe serve status --json' ] || exit 2
if [ "\${OMNI_DELAY_STAGE:-}" = status ]; then sleep "\${OMNI_STAGE_DELAY:-0}"; fi
cat '$service/status.json'
jq -e '.status == "running"' '$service/status.json' >/dev/null 2>&1 || exit 2
SHIM
  printf '#!/usr/bin/env bash\nfixture=%q\n' "$service" > "$tool_dir/curl"
  cat >> "$tool_dir/curl" <<'SHIM'
set -euo pipefail
[ "${OMNI_HEALTH:-ok}" = ok ] || exit 7
python3 - "$fixture" "$@" <<'PY'
import json, os, pathlib, sys, time
service = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
url = args[-1]
method = args[args.index('--request') + 1] if '--request' in args else 'GET'
body = json.loads(args[args.index('--data') + 1]) if '--data' in args else None
with (service / 'requests.jsonl').open('a') as output:
    output.write(json.dumps({'method': method, 'url': url, 'body': body}, sort_keys=True) + '\n')
if url.endswith('/health'):
    print('{"status":"ok"}')
    sys.exit(0)
# Registered hosts for remote-server launches: OMNI_HOST_STATE selects
# online (default), offline, or missing; OMNI_HOST_REPORTED overrides the id.
if '/v1/hosts/' in url:
    host = url.rsplit('/', 1)[-1]
    state = os.environ.get('OMNI_HOST_STATE', 'online')
    code = 404 if state == 'missing' else 200
    response = json.dumps({'host_id': os.environ.get('OMNI_HOST_REPORTED', host), 'name': 'fixture-host',
                           'status': state} if code == 200 else {'error': 'not found'})
    pathlib.Path(args[args.index('--output') + 1]).write_text(response)
    sys.stdout.write(args[args.index('--write-out') + 1].replace('%{http_code}', str(code)))
    sys.exit(0)
mode = os.environ.get('OMNI_TITLE_MODE', '')
if mode == 'http-error':
    sys.exit(22)
if mode == 'slow':
    time.sleep(30)
if mode == 'invalid-json':
    print('{bad JSON')
    sys.exit(0)
if mode == 'oversized':
    print(json.dumps({'padding': '·' * 70000}, ensure_ascii=False))
    sys.exit(0)
result_file = service / 'result.json'
harness = json.loads(result_file.read_text())['argv'][0] if result_file.exists() else 'claude'
labels = {'claude': 'claude-code-native-ui', 'codex': 'codex-native-ui',
          'kiro': 'kiro-native-ui', 'agy': 'antigravity-native-ui'}
session = {'id': url.rsplit('/', 1)[-1], 'labels': {'omnigent.wrapper': labels[harness]},
           'created_at': time.time(), 'title': None, 'status': 'idle',
           'runner_online': True, 'archived': False}
if os.environ.get('OMNI_SESSION_HOST'):
    session['host_id'] = os.environ['OMNI_SESSION_HOST']
# Session reads for supervision: OMNI_SESSION_STATE selects the record shape;
# --output and --write-out keep the body and HTTP status separate like curl.
session['pending_elicitations'] = json.loads(os.environ.get('OMNI_PENDING', '[]'))
state = os.environ.get('OMNI_SESSION_STATE', 'alive')
code = 200
if state == 'runner-gone':
    session['runner_online'] = False
elif state == 'failed':
    session['status'] = 'failed'
elif state == 'archived':
    session['archived'] = True
elif state == 'missing':
    code = 404
elif state == 'server-error':
    code = 500
if method == 'PATCH' and body.get('archived') is True:
    if os.environ.get('OMNI_ARCHIVE_MODE') == 'http-error':
        sys.exit(22)
    with (service / 'archived.jsonl').open('a') as output:
        output.write(json.dumps({'id': session['id'], 'body': body}, sort_keys=True) + '\n')
    session['archived'] = True
    print(json.dumps(session))
    sys.exit(0)
if '--write-out' in args:
    session['padding'] = 'x' * int(os.environ.get('OMNI_SESSION_PADDING', '0'))
    response = json.dumps(session) if code == 200 else '{"error":"not found"}'
    if '--output' in args:
        pathlib.Path(args[args.index('--output') + 1]).write_text(response)
    else:
        sys.stdout.write(response)
    sys.stdout.write(args[args.index('--write-out') + 1].replace('%{http_code}', str(code)))
    sys.exit(0)
if mode == 'wrong-id':
    session['id'] = 'b' * 32
if mode == 'wrong-harness':
    session['labels']['omnigent.wrapper'] = 'unrelated'
if mode == 'old-session':
    session['created_at'] = 1
if method == 'PATCH':
    session['title'] = body['title'] if mode != 'wrong-title' else 'ignored'
    # Omnigent upserts PATCH labels into the existing set.
    if mode != 'drop-labels':
        session['labels'].update(body.get('labels') or {})
    (service / 'title.json').write_text(json.dumps(session))
print(json.dumps(session))
PY
SHIM
  cat > "$service/runtime/bin/omnigent" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in *--help)
  if [ "${OMNI_DELAY_STAGE:-}" = capability ]; then sleep "${OMNI_STAGE_DELAY:-0}"; fi
  printf '%s\n' "$*" >> "${0%/*}/help.log"
  printf '%s\n' "${OMNI_HELP-  --env KEY=VALUE
Capabilities:
  claude-account-enforcement --env CLAUDE_CONFIG_DIR=<dir> selects the}"
  exit 0 ;;
esac
python3 - "$0" "$@" <<'PY'
import json, os, pathlib, subprocess, sys, time
# A remote-server launch has no Kit client environment; find the service from
# this double's own location instead.
config_home = os.environ.get('OMNIGENT_CONFIG_HOME')
service = pathlib.Path(config_home).parent if config_home else pathlib.Path(sys.argv[1]).resolve().parents[2]
args = sys.argv[2:]
(service / 'title.json').unlink(missing_ok=True)
environment = {}
for index, value in enumerate(args[:-1]):
    if value == '--env':
        name, text = args[index + 1].split('=', 1)
        environment[name] = text
with (service / 'result.json').open('w') as output:
    json.dump({'executable': sys.argv[1], 'argv': args, 'environment': environment,
               'pid': os.getppid(),
               'client_encoding': subprocess.check_output(['locale', 'charmap'], text=True).strip(),
               'config_home': os.environ.get('OMNIGENT_CONFIG_HOME')}, output)
with (service / 'requests.jsonl').open('a') as output:
    output.write(json.dumps({'event': 'launch'}) + '\n')
mode = os.environ.get('OMNI_RECORD_MODE', '')
if mode != 'missing':
    # Like the real CLI, the record names the server this launch was given.
    server = args[args.index('--server') + 1].rstrip('/') if '--server' in args else 'http://127.0.0.1:6767'
    record = ('Web UI: ' + server + '/c/' + 'a' * 32 + '\n').encode()
    if mode == 'wrong-server':
        record = record.replace(b':6767', b':6768')
    if mode == 'malformed':
        record = record.replace(b'a' * 32, b'../other')
    if mode == 'fragmented':
        record = b'\r\x1b[2K' + record
        for part in (record[:7], record[7:35], record[35:]):
            os.write(2, part)
            time.sleep(0.05)
    else:
        os.write(2, record)
if os.environ.get('OMNI_STDOUT_RECORD'):
    print('Web UI: http://127.0.0.1:6767/c/' + 'b' * 32, flush=True)
if mode in ('', 'fragmented') and not os.environ.get('OMNI_TITLE_MODE'):
    # The real CLI stays attached. Keep this short-lived double alive until
    # its launch metadata work finishes, so later cases cannot replace it.
    for _ in range(100):
        if (service / 'title.json').exists():
            break
        time.sleep(0.05)
PY
if [ "${OMNI_HOLD:-}" = 1 ]; then
  trap 'exit 143' TERM
  deadline=$((SECONDS + ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}))
  while [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
fi
exit "${OMNI_EXIT:-0}"
SHIM
  # The runtime interpreter runs the launcher's account lookup against a
  # stand-in of Omnigent's account API. YAML is a JSON superset, so fixtures
  # spell config.yaml as JSON; a missing file is an empty config, as in Omnigent.
  mkdir -p "$service/runtime/fake-site/omnigent/onboarding" "$service/runtime/fake-site/omnigent/host"
  : > "$service/runtime/fake-site/omnigent/__init__.py"
  : > "$service/runtime/fake-site/omnigent/onboarding/__init__.py"
  : > "$service/runtime/fake-site/omnigent/host/__init__.py"
  # Omnigent keeps a host's identity in the config's host section. Without
  # OMNIGENT_CONFIG_HOME this double reads its own service's config, never ~.
  cat > "$service/runtime/fake-site/omnigent/host/identity.py" <<'PY'
import collections, json, os, pathlib
HostIdentity = collections.namedtuple('HostIdentity', 'host_id name')
def load_host_identity_if_present(path=None):
    home = os.environ.get('OMNIGENT_CONFIG_HOME') or pathlib.Path(__file__).resolve().parents[4] / 'config'
    path = pathlib.Path(path or pathlib.Path(home) / 'config.yaml')
    host = (json.loads(path.read_text()) if path.exists() else {}).get('host') or {}
    return HostIdentity(host['host_id'], host.get('name', '')) if host.get('host_id') else None
PY
  cat > "$service/runtime/fake-site/omnigent/config.py" <<'PY'
import json, os, pathlib
def load_global_config():
    path = pathlib.Path(os.environ['OMNIGENT_CONFIG_HOME']) / 'config.yaml'
    return json.loads(path.read_text()) if path.exists() else {}
PY
  cat > "$service/runtime/fake-site/omnigent/onboarding/claude_accounts.py" <<'PY'
def account_name_for_config_dir(config, config_dir):
    for name, entry in (config.get('providers') or {}).items():
        if (entry.get('kind') == 'subscription' and entry.get('cli') == 'claude'
                and entry.get('config_dir') == config_dir and name.startswith('claude-')
                and name != 'claude-subscription'):
            return name[len('claude-'):]
    return None
PY
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsite=%q\n' "$service/runtime/fake-site" > "$service/runtime/bin/python"
  cat >> "$service/runtime/bin/python" <<'SHIM'
[ "${1:-}" != -I ] || shift
PYTHONPATH=$site exec python3 "$@"
SHIM
  chmod +x "$tool_dir/agent-kit" "$tool_dir/curl" "$service/runtime/bin/omnigent" "$service/runtime/bin/python"
}
