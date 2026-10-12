from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/davidtandoh/.no-mistakes/evidence/01M4RVJMH4JHMNHE5ZF0EWE795')
rows = []
with tempfile.TemporaryDirectory(prefix='.availability-live-', dir=str(ROOT)) as tmp:
    home = Path(tmp)
    for directory in ('data', 'state', 'config'):
        (home / directory).mkdir()
    ssh = home / 'ssh-isolated'
    ssh.write_text('#!/bin/sh\nexec /usr/bin/ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=2 "$@"\n')
    ssh.chmod(0o700)
    env = dict(os.environ)
    for key in list(env):
        if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
            env.pop(key)
    env.update(FM_HOME=str(home), FM_SSH_BIN=str(ssh), LC_ALL='C', LANG='C')
    registry = home / 'data/secondmates.md'
    meta = home / 'state/lap.meta'
    def register(extra):
        registry.write_text('- lap - Laptop hands (host: fm-lab-unavailable.invalid; root: /unavailable/root; home: /unavailable/home; ' + extra + 'scope: laptop work; projects: alpha; added 2026-10-12)\n')
    def hashes():
        return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
    def drive(name, args, expected_rc, prefix):
        before = hashes()
        start = time.monotonic()
        command = [str(ROOT / 'bin/fm-secondmate-availability.sh')] + args
        completed = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        row = dict(name=name, command='FM_HOME=<isolated-home> FM_SSH_BIN=<real-OpenSSH-wrapper> bin/fm-secondmate-availability.sh ' + ' '.join(args), exit=completed.returncode, stdout=completed.stdout.strip(), stderr=completed.stderr.strip(), duration_seconds=round(time.monotonic()-start,3), records_unchanged=before == hashes())
        rows.append(row)
        assert completed.returncode == expected_rc and completed.stdout.startswith(prefix) and row['records_unchanged'], row
    register('availability: when-online; ')
    meta.write_text('window=remote:lap\nkind=secondmate\nharness=claude\nremote_host=fm-lab-unavailable.invalid\nremote_backend=herdr\nremote_herdr_session=fm-lab-unavailable\nremote_target=fm-lab-unavailable:w1:p1\nhome=/unavailable/home\n')
    transport = subprocess.run([str(ssh), 'fm-lab-unavailable.invalid', 'true'], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    rows.append(dict(name='Real OpenSSH transport preflight', exit=transport.returncode, stdout=transport.stdout.strip(), stderr=transport.stderr.strip()))
    assert transport.returncode == 255
    drive('Unreachable host returns local for portable work', ['lap', 'portable'], 1, 'local lap:')
    drive('Unreachable host returns queue for host-bound work', ['lap', 'host-bound'], 1, 'queue lap:')
    meta.unlink()
    drive('Unlaunched laptop returns queue', ['lap', 'host-bound'], 1, 'queue lap: no running remote endpoint')
    register('')
    drive('Existing always-on route still routes', ['lap'], 0, 'route lap: always-on route;')
    register('availability: typo; ')
    drive('Malformed availability refuses routing', ['lap'], 2, '')
EVIDENCE.joinpath('manual-availability.json').write_text(json.dumps(dict(surface='Real availability CLI with real OpenSSH DNS failure; no SSH replies simulated. Does not prove agent dispatch or backlog persistence.', scenarios=rows, transient_home_removed=True), indent=2, sort_keys=True) + '\n')
for row in rows:
    print(json.dumps(row, sort_keys=True))
