from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import sys
import time

out = Path('/Users/davidtandoh/.no-mistakes/evidence/01M4JM42HNVEZ5DY2788J32D2V/focused-r2')
label, script, selector, *args = sys.argv[1:]
env = dict(os.environ, FM_TEST_ONLY=selector, FM_TEST_SKIP_ORPHAN_REAP='1')
command = ['bash', '-c', '. bin/fm-timeout-lib.sh; fm_exec_timed 60 5 "$@"', '_', 'bash', '-x', script] + args
started = time.monotonic()
with (out / (label + '.log')).open('w') as log:
    proc = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
record = dict(command=command, selector=selector, args=args, exit=proc.returncode,
              duration_ms=round((time.monotonic()-started)*1000), gate_skip=False,
              log=str(out / (label + '.log')), live=False)
with (out / (label + '.json')).open('w') as target:
    json.dump(record, target, sort_keys=True)
    target.write('\n')
print(json.dumps(record, sort_keys=True))
sys.exit(proc.returncode)
