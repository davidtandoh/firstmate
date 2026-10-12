from __future__ import annotations
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path.cwd()
E = Path('/Users/davidtandoh/.no-mistakes/evidence/01M4PNWW27JM5K5V2XTQ5VS8GJ')
LAB = ROOT / '.nm-live-races'
env = dict(os.environ, LC_ALL='C', LANG='C', FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_ARM_CONFIRM_TIMEOUT='30')
for key in list(env):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ('FM_GATE_REFUSE_BYPASS','FM_TASK_ID','FM_SUPERVISION_ACTOR','FM_TEST_SEAM'):
        env.pop(key)
log = (E / 'live-races.log').open('w')
active = []
files = []
results = []

def record(text):
    log.write(text + '\n')
    log.flush()
    print(text, flush=True)

def run(args, home=None):
    local = dict(env)
    if home is not None:
        local['FM_HOME'] = str(home)
    p = subprocess.run(args, env=local, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=45)
    log.write('$ ' + ' '.join(str(x) for x in args) + '\n' + p.stdout + 'exit=' + str(p.returncode) + '\n')
    log.flush()
    if p.returncode:
        raise RuntimeError(p.stdout)
    return p.stdout

def read(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return ''

def until(predicate, bound=30, interval=.01):
    end = time.monotonic() + bound
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(interval)
    raise RuntimeError('Timed out waiting for observable state')

def start(args, home, name):
    path = E / (name + '.log')
    out = path.open('w')
    files.append(out)
    p = subprocess.Popen(args, env=dict(env, FM_HOME=str(home)), cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    active.append(p)
    return p, path

def append(home, payload):
    run(['/bin/bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check race "$1"','_',payload], home)

def drain_pair(home):
    out = run(['bin/fm-wake-drain.sh'],home)
    match = re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',out)
    assert match, out
    return match[1], match[2]

def acknowledge(home):
    seq, generation = drain_pair(home)
    run(['bin/fm-wake-drain.sh','--ack-through',seq,'--recovery-generation',generation],home)

try:
    run(['bin/fm-lab-home.sh','create',str(LAB)])
    env['TMUX_TMPDIR'] = run(['bin/fm-lab-home.sh','tmux-dir',str(LAB)]).strip()
    run(['tmux','-L','fm-lab','new-session','-d','-s','cli','-c',str(ROOT),'/bin/sh'])
    env['TMUX'] = run(['tmux','-L','fm-lab','display-message','-p','-t','cli','#{socket_path},#{pid},0']).strip()
    # Pause the real drain process group after its marker commit. No wrapped
    # mv, alternate PATH, or test seam is used.
    home = LAB / 'ack-overlap'
    run(['bin/fm-lab-home.sh','create',str(home)])
    arm, arm_path = start(['bin/fm-watch-arm.sh'],home,'race-ack-owner')
    until(lambda:'watcher: started pid=' in read(arm_path))
    watcher = int(read(home / 'state/.watch.lock/pid'))
    os.kill(watcher,signal.SIGSTOP)
    append(home,'check: acknowledgement overlaps native watcher shutdown')
    seq, generation = drain_pair(home)
    drain, drain_path = start(['bin/fm-wake-drain.sh','--ack-through',seq,'--recovery-generation',generation],home,'race-ack-process')
    marker = home / 'state/.watcher-down'
    until(lambda:read(marker).startswith('acked:'), interval=.0005)
    os.killpg(drain.pid,signal.SIGSTOP)
    time.sleep(.05)
    assert drain.poll() is None, 'Pause missed the acknowledgement transaction'
    assert (home / 'state/.wake-queue').stat().st_size > 0, 'Pause occurred after queue replacement'
    before = read(marker)
    record('ack-overlap: real acknowledgement paused; marker=' + before.strip() + '; queue remains nonempty')
    os.kill(watcher,signal.SIGTERM)
    os.kill(watcher,signal.SIGCONT)
    assert arm.wait(timeout=30) == 143
    assert read(marker) == before
    assert read(home / 'state/.watch.lock/pid').strip() == str(watcher)
    record('ack-overlap: bounded shutdown preserved marker and stale watcher evidence')
    os.killpg(drain.pid,signal.SIGCONT)
    assert drain.wait(timeout=30) == 0
    assert (home / 'state/.wake-queue').stat().st_size == 0
    next_arm, path = start(['bin/fm-watch-arm.sh'],home,'race-ack-next-arm')
    until(lambda:'watcher: started pid=' in read(path))
    time.sleep(5)
    assert next_arm.poll() is None and read(marker) == before
    assert 'check: rearm-resurface' not in read(path)
    append(home,'check: new durable work after overlapping acknowledgement')
    assert next_arm.wait(timeout=30) == 0
    assert 'check: rearm-resurface' in read(path)
    acknowledge(home)
    record('ack-overlap: PASS; committed acknowledgement stayed quiet, later durable work resurfaced')
    results.append({'scenario':'ack-overlap','result':'pass','live':True})
    # Observe the persisted marker and stop the actual watcher before its
    # recovery output. The race outcome is checked explicitly.
    home = LAB / 'announcement-interruption'
    run(['bin/fm-lab-home.sh','create',str(home)])
    run(['/bin/bash','-c','. bin/fm-wake-lib.sh; fm_recovery_marker_publish "$STATE/.watcher-down" handling; fm_recovery_marker_publish "$STATE/.watcher-down" downtime'],home)
    marker = home / 'state/.watcher-down'
    generation = read(marker).strip().split(':')[-1]
    arm, path = start(['bin/fm-watch-arm.sh'],home,'race-announcement-owner')
    until(lambda:read(marker).startswith('announced:downtime:'),interval=.0005)
    watcher = int(read(home / 'state/.watch.lock/pid'))
    os.kill(watcher,signal.SIGKILL)
    assert arm.wait(timeout=30) != 0
    assert 'check: rearm-resurface' not in read(path), 'Watcher delivered before interruption'
    assert read(marker).strip() == 'announced:downtime:' + generation
    assert read(home / 'state/.watch.lock/pid').strip() == str(watcher)
    record('announcement-interruption: watcher killed after announcement and before delivery; generation=' + generation)
    retry, retry_path = start(['bin/fm-watch-arm.sh'],home,'race-announcement-retry')
    assert retry.wait(timeout=40) == 0
    assert 'check: rearm-resurface' in read(retry_path)
    seq, retried_generation = drain_pair(home)
    assert seq == '0' and retried_generation == generation
    run(['bin/fm-wake-drain.sh','--ack-through',seq,'--recovery-generation',generation],home)
    before = read(marker)
    quiet, quiet_path = start(['bin/fm-watch-arm.sh'],home,'race-announcement-after-ack')
    until(lambda:'watcher: started pid=' in read(quiet_path))
    time.sleep(5)
    assert quiet.poll() is None and read(marker) == before
    assert 'check: rearm-resurface' not in read(quiet_path)
    append(home,'check: real work after recovered announcement')
    assert quiet.wait(timeout=30) == 0
    acknowledge(home)
    record('announcement-interruption: PASS; retry retained generation, acknowledgement stopped replay, later work woke')
    results.append({'scenario':'announcement-interruption','result':'pass','live':True})
finally:
    for p in active:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGCONT)
            os.killpg(p.pid,signal.SIGTERM)
            try:
                p.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL)
                p.wait(timeout=5)
    for home in (LAB / 'ack-overlap',LAB / 'announcement-interruption'):
        if home.is_dir():
            run(['bin/fm-watch-arm.sh','--stop'],home)
    if 'TMUX_TMPDIR' in env and LAB.exists():
        run(['tmux','-L','fm-lab','kill-server'])
        run(['bin/fm-lab-home.sh','teardown',str(LAB)])
        shutil.rmtree(LAB)
    (E / 'live-race-results.json').write_text(json.dumps(results,sort_keys=True,indent=2) + '\n')
    for file in files:
        file.close()
    log.close()
