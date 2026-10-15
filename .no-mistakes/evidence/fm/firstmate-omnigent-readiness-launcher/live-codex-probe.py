from __future__ import annotations
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request

root = Path.cwd()
lab = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root))
env = os.environ.copy()
for key in ('NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)
env['FM_HOME'] = str(lab)
conversation = None
socket = None
server_started = False

def run(args, **kwargs):
    return subprocess.run(args, env=env, check=True, text=True, capture_output=True, timeout=20, **kwargs).stdout

def tmux(*args):
    return run(['tmux', '-L', 'fm-lab', *args])

def terminals(url, method='GET'):
    with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=5) as response:
        data = response.read(1048577)
        if len(data) > 1048576:
            raise RuntimeError('oversized terminal response')
        return json.loads(data) if data else None

try:
    print(run(['bin/fm-lab-home.sh', 'create', str(lab)]), end='')
    socket = run(['bin/fm-lab-home.sh', 'tmux-dir', str(lab)]).strip()
    env['TMUX_TMPDIR'] = socket
    selection = json.loads(run(['bin/fm-omnigent.sh', 'run', '--dry-run', 'codex']))
    print('Selected runtime: ' + json.dumps(selection, sort_keys=True), flush=True)
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'primary', '-c', str(root), '-x', '120', '-y', '40', '-e', 'FM_HOME=' + str(lab), str(root / 'bin/fm-omnigent.sh'), 'run', 'codex', '--dangerously-bypass-approvals-and-sandbox', '--disable', 'hooks', '')
    server_started = True
    screen = ''
    for _ in range(100):
        time.sleep(0.3)
        screen = tmux('capture-pane', '-p', '-t', 'primary', '-S', '-100')
        match = re.search(re.escape(selection['server_url'].rstrip('/') + '/c/') + r'([a-f0-9]{32})', screen)
        if match:
            conversation = match.group(1)
        if conversation and ('OpenAI Codex' in screen or 'codex-cli' in screen):
            break
    print('Owned pane capture:\n' + screen, flush=True)
    if not conversation:
        raise RuntimeError('No session footer in owned pane; cannot prove wrapped launch')
    endpoint = selection['server_url'].rstrip('/') + '/v1/sessions/' + conversation + '/resources/terminals'
    records = terminals(endpoint)
    if records.get('object') != 'list' or records.get('has_more') is not False:
        raise RuntimeError('Unverified terminal list')
    if not records['data'] or any(row.get('session_id') != conversation or row.get('type') != 'terminal' for row in records['data']):
        raise RuntimeError('No attributed terminal resource')
    print('Attributed terminal resources: ' + json.dumps([{key: row.get(key) for key in ('id', 'session_id', 'type', 'status')} for row in records['data']], sort_keys=True), flush=True)
    if 'OpenAI Codex' not in screen and 'codex-cli' not in screen:
        raise RuntimeError('Native Codex startup not observed')
    print('PASS: selected real launcher opened native Codex without a model prompt', flush=True)
finally:
    try:
        if conversation:
            endpoint = selection['server_url'].rstrip('/') + '/v1/sessions/' + conversation + '/resources/terminals'
            records = terminals(endpoint)
            if records.get('object') != 'list' or records.get('has_more') is not False:
                raise RuntimeError('Cleanup refused incomplete terminal list')
            for row in records['data']:
                if row.get('session_id') != conversation or row.get('type') != 'terminal' or not re.fullmatch(r'[A-Za-z0-9_-]+', row['id']):
                    raise RuntimeError('Cleanup refused unowned terminal')
                terminals(endpoint + '/' + row['id'], 'DELETE')
            remaining = terminals(endpoint)
            if remaining.get('data') != [] or remaining.get('has_more') is not False:
                raise RuntimeError('Terminal cleanup incomplete')
            print('Cleanup: owned session terminal list is empty', flush=True)
    finally:
        if server_started:
            tmux('kill-server')
        if socket:
            run(['bin/fm-lab-home.sh', 'teardown', str(lab)])
        shutil.rmtree(lab)
        print('Cleanup: private tmux server and disposable lab home removed', flush=True)
