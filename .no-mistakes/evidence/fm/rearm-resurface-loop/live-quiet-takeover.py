from __future__ import annotations
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
lab = pathlib.Path(tempfile.mkdtemp(prefix=".fm-gate-live-", dir=str(root)))
env = dict(os.environ)
for key in list(env):
    if key.startswith("FM_") or key in ("TMUX", "HERDR_SESSION"):
        env.pop(key, None)
env.update(FM_HOME=str(lab), FM_POLL="1", FM_SIGNAL_GRACE="0", FM_CHECK_INTERVAL="1", FM_HEARTBEAT="999999", FM_ARM_CONFIRM_TIMEOUT="20")
arms = []
handles = []

def run(args):
    result = subprocess.run(args, env=env, cwd=str(root), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    print("COMMAND", " ".join(args), "EXIT", result.returncode, flush=True)
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", flush=True)
    if result.returncode:
        raise RuntimeError("command failed")
    return result

def arm(args, predecessor=None):
    output = evidence / ("live-arm-%d.log" % len(arms))
    stream = output.open("w")
    handles.append(stream)
    child_env = dict(env)
    if predecessor:
        child_env["FM_WATCH_PREDECESSOR_ARM_PID"] = str(predecessor)
    process = subprocess.Popen([str(root / "bin/fm-watch-arm.sh")] + args, env=child_env, stdout=stream, stderr=subprocess.STDOUT, cwd=str(root))
    arms.append(process)
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        text = output.read_text()
        if "watcher: started pid=" in text:
            print(text, end="", flush=True)
            return process, output
        if process.poll() is not None:
            raise RuntimeError("arm ended: " + text)
        time.sleep(0.1)
    raise RuntimeError("arm confirmation timeout")

try:
    run([str(root / "bin/fm-lab-home.sh"), "create", str(lab)])
    owner, output = arm(["--restart"], os.getpid())
    run(["/bin/bash", "-c", '. "$1"; fm_wake_append check gate-live "check: handled live validation event"', "_", str(root / "bin/fm-wake-lib.sh")])
    result = run([str(root / "bin/fm-wake-drain.sh")])
    match = re.search(r"--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)", result.stderr)
    if not match:
        raise RuntimeError("missing acknowledgement contract")
    run([str(root / "bin/fm-wake-drain.sh"), "--ack-through", match[1], "--recovery-generation", match[2]])
    marker = (lab / "state/.watcher-down").read_text()
    print("ACKNOWLEDGED", marker.strip(), flush=True)
    for cycle in range(3):
        prior = owner
        owner, output = arm(["--take-over", str(prior.pid)])
        prior.wait(timeout=10)
        time.sleep(3)
        assert owner.poll() is None, output.read_text()
        assert (lab / "state/.watcher-down").read_text() == marker
        queue = lab / "state/.wake-queue"
        assert not queue.exists() or queue.stat().st_size == 0
        assert "check: rearm-resurface" not in output.read_text()
        print("TAKEOVER", cycle + 1, "acknowledgement unchanged; queue empty; no repeated recovery wake", flush=True)
    check = lab / "state/blocked.check.sh"
    check.write_text('#!/bin/bash\n: > "' + str(lab / "state/check-entered") + '"\nexec sleep 60\n')
    check.chmod(0o700)
    run([str(root / "bin/fm-check-register.sh"), "blocked"])
    deadline = time.monotonic() + 20
    while not (lab / "state/check-entered").exists():
        if time.monotonic() > deadline:
            raise RuntimeError("registered check never entered")
        time.sleep(0.1)
    check.unlink()
    prior = owner
    started = time.monotonic()
    owner, output = arm(["--take-over", str(prior.pid)])
    prior.wait(timeout=10)
    assert (lab / "state/.watcher-down").read_text() == marker
    print("BLOCKED CHECK TAKEOVER preserved acknowledgement in %.2fs" % (time.monotonic() - started), flush=True)
    (lab / "state/later.status").write_text("done: later real work\n")
    print("STATUS APPEND done: later real work", flush=True)
    owner.wait(timeout=20)
    print(output.read_text(), end="", flush=True)
    assert "signal:" in output.read_text()
    run([str(root / "bin/fm-wake-drain.sh")])
    print("LATER WORK delivered", flush=True)
finally:
    try:
        run([str(root / "bin/fm-watch-arm.sh"), "--stop"])
    finally:
        for process in arms:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for stream in handles:
            stream.close()
        for name in (".watch-cycle-exits.log", ".watcher-down", ".wake-queue"):
            source = lab / "state" / name
            if source.exists():
                shutil.copyfile(str(source), str(evidence / ("live" + name)))
        shutil.rmtree(str(lab))
        print("LAB REMOVED", flush=True)
