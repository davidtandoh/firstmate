from __future__ import annotations
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path.cwd()
EVIDENCE = Path('/Users/davidtandoh/.no-mistakes/evidence/01M4PNWW27JM5K5V2XTQ5VS8GJ')
LAB = ROOT / '.nm-live-home'
BASE = dict(os.environ)
for key in ('FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TASK_ID', 'FM_SUPERVISION_ACTOR', 'FM_TEST_SEAM'):
    BASE.pop(key, None)
BASE.update(LC_ALL='C', LANG='C', FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_ARM_CONFIRM_TIMEOUT='30')
BASE['TMUX_TMPDIR'] = (LAB / 'state/.fm-lab-tmux-dir').read_text().strip()
BASE['TMUX'] = subprocess.check_output(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'primary', '#{socket_path},#{pid},0'], env=BASE, text=True).strip()
RESULTS = []

def call(args, env, log):
    p = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
    log.write('$ ' + ' '.join(str(a) for a in args) + '\n' + p.stdout + 'exit=' + str(p.returncode) + '\n')
    log.flush()
    if p.returncode:
        raise RuntimeError('Command failed: ' + str(args))
    return p.stdout

def append(env, payload, log):
    return call(['/bin/bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_append check lab "$1"', '_', payload], env, log)

def ack(env, log):
    text = call(['bin/fm-wake-drain.sh'], env, log)
    match = re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', text)
    assert match, text
    call(['bin/fm-wake-drain.sh', '--ack-through', match[1], '--recovery-generation', match[2]], env, log)
    return text

def wait_until(predicate, seconds=35):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.1)
    raise RuntimeError('Observable state did not arrive within bound')

for mode in ('TERM', 'HUP', 'KILL', 'interpreter-failure'):
    home = LAB / mode
    env = dict(BASE, FM_HOME=str(home))
    active = []
    with (EVIDENCE / ('live-' + mode + '.log')).open('w') as log:
        try:
            call(['bin/fm-lab-home.sh', 'create', str(home)], env, log)
            append(env, 'check: handled initial lab work', log)
            ack(env, log)
            marker = home / 'state/.watcher-down'
            initial = marker.read_text()
            assert initial.startswith('acked:')
            log.write('acknowledged_marker=' + initial)
            first_path = EVIDENCE / ('live-' + mode + '-first-arm.log')
            with first_path.open('w') as out:
                first_env = dict(env)
                if mode == 'interpreter-failure':
                    first_env['FM_HEARTBEAT'] = 'invalid'
                arm = subprocess.Popen(['bin/fm-watch-arm.sh'], env=first_env, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
                active.append(arm)
                if mode != 'interpreter-failure':
                    wait_until(lambda: 'watcher: started pid=' in first_path.read_text())
                    watcher = int((home / 'state/.watch.lock/pid').read_text())
                    time.sleep(3)
                    os.kill(watcher, getattr(signal, 'SIG' + mode))
                    log.write('sent=' + mode + ' watcher_pid=' + str(watcher) + '\n')
                result = arm.wait(timeout=40)
                log.write('first_arm_exit=' + str(result) + '\n')
                assert result == {'TERM':143, 'HUP':129, 'KILL':137, 'interpreter-failure':1}[mode], result
            next_path = EVIDENCE / ('live-' + mode + '-next-arm.log')
            with next_path.open('w') as out:
                arm = subprocess.Popen(['bin/fm-watch-arm.sh'], env=env, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
                active.append(arm)
                wait_until(lambda: 'watcher: started pid=' in next_path.read_text())
                time.sleep(6)
                assert arm.poll() is None, next_path.read_text()
                assert marker.read_text() == initial, marker.read_text()
                assert 'check: rearm-resurface' not in next_path.read_text(), next_path.read_text()
                log.write('after_rearm=live_and_quiet_for_6_seconds\nmarker_unchanged=true\nqueue_bytes=' + str((home / 'state/.wake-queue').stat().st_size) + '\n')
                append(env, 'check: later real work after ' + mode, log)
                assert arm.wait(timeout=40) == 0
                assert 'check: rearm-resurface' in next_path.read_text(), next_path.read_text()
                delivered = ack(env, log)
                assert 'check: later real work after ' + mode in delivered
                log.write('later_work=delivered_and_acknowledged\nresult=pass\n')
            RESULTS.append({'name': mode, 'result':'pass'})
        except Exception as exc:
            log.write('ERROR: ' + repr(exc) + '\n')
            RESULTS.append({'name':mode, 'result':'fail', 'error':str(exc)})
            raise
        finally:
            for arm in active:
                if arm.poll() is None:
                    arm.terminate()
                    try:
                        arm.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        arm.kill()
                        arm.wait(timeout=5)
            if home.exists():
                call(['bin/fm-watch-arm.sh', '--stop'], env, log)
            (EVIDENCE / 'live-cli-results.json').write_text(json.dumps(RESULTS, sort_keys=True, indent=2) + '\n')
    print(mode + ': pass', flush=True)
