from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent


def bounded_text(path):
    if not path.exists():
        return ''
    with path.open('rb') as stream:
        data = stream.read(1048577)
    if len(data) > 1048576:
        raise RuntimeError('Evidence exceeds 1 MiB: ' + str(path))
    return data.decode('utf-8', errors='replace')


def stop(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGCONT)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def run_case(name, budget, stalled, base_commit=None):
    lab = Path(tempfile.mkdtemp(prefix='.live-ssh-', dir=str(ROOT)))
    server = watcher = None
    handles = []
    env = dict(os.environ)
    for key in list(env):
        if key.startswith('FM_') or key in ('TMUX', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
            env.pop(key, None)
    env['LC_ALL'] = 'C'
    result = {'name': name, 'budget': budget, 'stalled_real_sshd': stalled,
              'base_library_commit': base_commit}
    try:
        home = lab / 'home'
        subprocess.run([str(ROOT / 'bin/fm-lab-home.sh'), 'create', str(home)],
                       check=True, capture_output=True, env=env)
        (lab / 'tmux').mkdir()
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '',
                        '-f', str(lab / 'host_key')], check=True, capture_output=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        config = lab / 'sshd_config'
        config.write_text('ListenAddress 127.0.0.1\nPort ' + str(port) +
                          '\nHostKey ' + str(lab / 'host_key') +
                          '\nPidFile ' + str(lab / 'sshd.pid') +
                          '\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n'
                          'UsePAM no\nAuthorizedKeysFile none\n')
        server_log = (EVIDENCE / (name + '-sshd.log')).open('w')
        handles.append(server_log)
        server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)],
                                  stdout=server_log, stderr=server_log, start_new_session=True)
        time.sleep(0.4)
        if server.poll() is not None:
            raise RuntimeError('Private sshd did not start')
        if stalled:
            os.killpg(server.pid, signal.SIGSTOP)
        else:
            stop(server)
        # This adapter adds isolated OpenSSH configuration only. It neither
        # fabricates remote output nor replaces the SSH protocol implementation.
        adapter = lab / 'ssh-isolated'
        ssh_log = EVIDENCE / (name + '-ssh.log')
        adapter.write_text('#!/bin/bash\nset -euo pipefail\nexec /usr/bin/ssh -F /dev/null '
                           '-o BatchMode=yes -o HostName=127.0.0.1 -o ConnectTimeout=30 '
                           '-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null '
                           '-o GlobalKnownHostsFile=/dev/null -p ' + str(port) +
                           ' -vv -E ' + shlex.quote(str(ssh_log)) + ' "$@"\n')
        adapter.chmod(0o700)
        meta = home / 'state/rsm1.meta'
        registry = home / 'data/secondmates.md'
        meta.write_text('window=remote:rsm1\nkind=secondmate\nharness=claude\n'
                        'remote_host=lab-only\nremote_backend=herdr\n'
                        'remote_herdr_session=fm-lab-timeout\n'
                        'remote_target=fm-lab-timeout:w1:p1\nhome=' + str(lab / 'remote') + '\n')
        registry.write_text('- rsm1 - Disposable SSH check (host: lab-only; root: ' + str(ROOT) +
                            '; home: ' + str(lab / 'remote') +
                            '; scope: timeout validation; projects: none; added 2026-10-06)\n')
        before = {str(p.relative_to(home)): hashlib.sha256(bounded_text(p).encode()).hexdigest()
                  for p in (meta, registry)}
        env.update(FM_HOME=str(home), FM_SSH_BIN=str(adapter), FM_BACKEND='tmux',
                   TMUX_TMPDIR=str(lab / 'tmux'), TMUX='', FM_POLL='1',
                   FM_SECONDMATE_LIVENESS_SECS='60', FM_HEARTBEAT='999999',
                   FM_CHECK_INTERVAL='999999', FM_SIGNAL_GRACE='0')
        if budget is not None:
            env['FM_SECONDMATE_LIVENESS_PROBE_TIMEOUT'] = budget
        executable = ROOT / 'bin/fm-watch.sh'
        if base_commit:
            # Run the same watcher with only the changed library restored to
            # base, inside this owned disposable directory. No checkout edits.
            shutil.copytree(str(ROOT / 'bin'), str(lab / 'bin'))
            base = subprocess.run(['git', 'show', base_commit + ':bin/fm-secondmate-liveness-lib.sh'],
                                  check=True, capture_output=True).stdout
            (lab / 'bin/fm-secondmate-liveness-lib.sh').write_bytes(base)
            executable = lab / 'bin/fm-watch.sh'
            env['FM_ROOT_OVERRIDE'] = str(ROOT)
        output = (EVIDENCE / (name + '-watcher.log')).open('w')
        handles.append(output)
        started = time.monotonic()
        watcher = subprocess.Popen([str(executable)], env=env,
                                   stdout=output, stderr=output, start_new_session=True)
        beats = []
        triage = home / 'state/.watch-triage.log'
        beat = home / 'state/.last-watcher-beat'
        expected = 'state probe timed out after ' if stalled else 'remote host unavailable'
        while time.monotonic() - started < 18:
            if beat.exists():
                stamp = beat.stat().st_mtime_ns
                if not beats or stamp != beats[-1]['mtime_ns']:
                    beats.append({'elapsed_seconds': round(time.monotonic() - started, 3),
                                  'mtime_ns': stamp})
            if expected in bounded_text(triage) and len(beats) >= 2:
                break
            if watcher.poll() is not None:
                break
            time.sleep(0.1)
        result.update(elapsed_seconds=round(time.monotonic() - started, 3), beats=beats,
                      watcher_running=watcher.poll() is None, triage=bounded_text(triage),
                      ssh_transport=bounded_text(ssh_log), hashes_before=before,
                      hashes_after={str(p.relative_to(home)): hashlib.sha256(bounded_text(p).encode()).hexdigest()
                                    for p in (meta, registry)},
                      recovery_ledger_exists=(home / 'state/.secondmate-relaunch-rsm1').exists(),
                      wake_queue=bounded_text(home / 'state/.wake-queue'))
        result['pass'] = (result['watcher_running'] and len(beats) >= 2 and
                          expected in result['triage'] and result['hashes_before'] == result['hashes_after']
                          and not result['recovery_ledger_exists'] and not result['wake_queue'])
    finally:
        stop(watcher)
        stop(server)
        for handle in handles:
            handle.close()
        shutil.rmtree(str(lab))
    (EVIDENCE / (name + '.json')).write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True), flush=True)
    return result['pass']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Drive an isolated watcher through real SSH failure modes.')
    parser.add_argument('--base-library-commit')
    args = parser.parse_args()
    if args.base_library_commit:
        passed = run_case('live-base-regression', None, True, args.base_library_commit)
        raise SystemExit(0 if passed else 1)
    results = [run_case('live-default-timeout', None, True),
               run_case('live-one-second-timeout', '1', True),
               run_case('live-invalid-timeout', '00', True),
               run_case('live-unreachable', None, False)]
    raise SystemExit(0 if all(results) else 1)
