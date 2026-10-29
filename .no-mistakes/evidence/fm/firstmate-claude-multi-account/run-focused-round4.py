from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(__file__).parent
label = sys.argv[1]
limit = int(sys.argv[2])
command = sys.argv[3:]
log = root / (label + '.log')
start = time.monotonic()
timed_out = False
with log.open('w') as output:
    output.write('command: ' + ' '.join(command) + '\n')
    output.flush()
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        code = 124
text = log.read_text()
record = {'command': command, 'duration_ms': round((time.monotonic() - start) * 1000), 'exit': code, 'gate_skip': 'skip:' in text, 'gate_skip_reason': [line for line in text.splitlines() if 'skip:' in line], 'timed_out': timed_out}
(root / (label + '-timing.json')).write_text(json.dumps(record, sort_keys=True) + '\n')
print(text, end='')
print(json.dumps(record, sort_keys=True))
sys.exit(code)
