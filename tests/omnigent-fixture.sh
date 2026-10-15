#!/usr/bin/env bash
# Isolated status/CLI contract double shared by local and SSH launch tests.
# The CLI records argv and the explicit native environment without model calls.
set -euo pipefail
fm_test_omnigent_service() { # <service-root> <tool-dir>
  local service=$1 tools=$2
  mkdir -p "$service/runtime/bin" "$tools"
  jq -n --arg state "$service/serve.json" --arg config "$service/config" \
    '{status:"running",server_url:"http://127.0.0.1:6767",state_file:$state,client_environment:{OMNIGENT_CONFIG_HOME:$config}}' > "$service/status.json"
  jq -n --arg executable "$service/runtime/bin/omnigent" \
    '{schema_version:"1",status:"unavailable",reasons:["serve_setup_headless_only","serve_web_assets_missing"],
      managed_status:{status:"running"},managed_service:{server_url:"http://127.0.0.1:6767"},
      runtime:{executable:$executable}}' > "$service/readiness.json"
  cat > "$tools/agent-kit" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
if [ "\$*" = 'observe serve status --readiness --json' ]; then
  cat '$service/readiness.json'
  jq -e '.status == "ready" or .status == "unavailable"' '$service/readiness.json' >/dev/null 2>&1 || exit 2
  exit 0
fi
[ "\$*" = 'observe serve status --json' ] || exit 2
cat '$service/status.json'
jq -e '.status == "running"' '$service/status.json' >/dev/null 2>&1 || exit 2
SHIM
  printf '#!/usr/bin/env bash\nfixture=%q\n' "$service" > "$tools/curl"
  cat >> "$tools/curl" <<'SHIM'
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
result = json.loads((service / 'result.json').read_text())
harness = result['argv'][0]
labels = {'claude': 'claude-code-native-ui', 'codex': 'codex-native-ui',
          'kiro': 'kiro-native-ui', 'agy': 'antigravity-native-ui'}
session = {'id': url.rsplit('/', 1)[-1], 'labels': {'omnigent.wrapper': labels[harness]},
           'created_at': time.time(), 'title': None}
if mode == 'wrong-id':
    session['id'] = 'b' * 32
if mode == 'wrong-harness':
    session['labels']['omnigent.wrapper'] = 'unrelated'
if mode == 'old-session':
    session['created_at'] = 1
if method == 'PATCH':
    session['title'] = body['title'] if mode != 'wrong-title' else 'ignored'
    (service / 'title.json').write_text(json.dumps(session))
print(json.dumps(session))
PY
SHIM
  cat > "$service/runtime/bin/omnigent" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in *--help) printf '  --env KEY=VALUE\n'; exit 0 ;; esac
python3 - "$0" "$@" <<'PY'
import json, os, pathlib, subprocess, sys, time
service = pathlib.Path(os.environ['OMNIGENT_CONFIG_HOME']).parent
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
    record = ('Web UI: http://127.0.0.1:6767/c/' + 'a' * 32 + '\n').encode()
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
  chmod +x "$tools/agent-kit" "$tools/curl" "$service/runtime/bin/omnigent"
}
