from __future__ import annotations
import json
import os
from pathlib import Path
import subprocess
import time

root = Path.cwd()
evidence = Path('/Users/davidtandoh/.no-mistakes/evidence/01M4PNWW27JM5K5V2XTQ5VS8GJ')
# Load the existing suite's setup and functions, then execute only the selected
# behavioral cases. All assertions and production commands remain unchanged.
with (root / 'tests/fm-supervision-host.test.sh').open() as source:
    suite = source.read(512 * 1024)
declarations = suite.split('\ntest_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main\n', 1)[0]
declarations = declarations.replace('. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"', '. "$PWD/tests/wake-helpers.sh"', 1)
selectors = [
    'test_next_park_takes_over_the_cycle_a_pass_through_left_for_main',
    'test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park',
    'test_undelivered_dialog_is_fed_again_on_the_next_turn',
]
script = declarations + '\n' + '\n'.join(selectors) + '\n'
env = dict(os.environ, LC_ALL='C', LANG='C')
started = time.monotonic()
with (evidence / 'host-focused.log').open('w') as log:
    log.write('Selected existing behavioral cases:\n' + '\n'.join(selectors) + '\n')
    log.flush()
    try:
        result = subprocess.run(['/bin/bash', '-c', '. bin/fm-timeout-lib.sh; fm_exec_timed 300 5 /bin/bash'], input=script, env=env, cwd=root, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=330)
        status = result.returncode
    except subprocess.TimeoutExpired:
        status = 124
    timing = {'script':'tests/fm-supervision-host.test.sh', 'selectors':selectors, 'exit':status, 'duration_ms':round((time.monotonic()-started)*1000), 'gate_skip':False, 'timeout':status == 124}
    log.write(json.dumps(timing, sort_keys=True) + '\n')
(evidence / 'host-focused-timing.json').write_text(json.dumps(timing, sort_keys=True, indent=2) + '\n')
print(json.dumps(timing, sort_keys=True))
raise SystemExit(status)
