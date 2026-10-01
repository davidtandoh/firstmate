from __future__ import annotations
import json, os, pathlib, shutil, subprocess, sys, time
root = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
scratch = root / '.test-pi-validation' / 'tmp'
scratch.mkdir(exist_ok=True)
env = dict(os.environ, LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8', FM_TEST_SKIP_ORPHAN_REAP='1', FM_PI_PACKAGE_DIR=str(root / '.test-pi-validation/node_modules/@earendil-works/pi-coding-agent'), TMPDIR=str(scratch))
env['PATH'] = str(root / '.test-pi-validation/node_modules/.bin') + ':' + env['PATH']
command = ['bin/fm-test-run.sh', 'tests/fm-calm-pi-extension.test.sh', '--jobs', '1', '--per-script-timeout-secs', '240', '--max-wall-ms', '260000', '--json', str(evidence / 'calm-timing.json')]
captured = set()
with (evidence / 'calm.log').open('wb') as log:
    child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    while child.poll() is None:
        for fixture in scratch.glob('fm-calm-pi-extension.*'):
            for name in ('calm-export.html', 'calm-export-dom.html', 'default.txt', 'hidden.txt', 'export.txt', 'calm-session.jsonl'):
                source = fixture / name
                try:
                    if source.is_file() and source.stat().st_size:
                        shutil.copyfile(source, evidence / name)
                        captured.add(name)
                except FileNotFoundError:
                    pass
        time.sleep(0.2)
result = {'command': command, 'exit': child.returncode, 'captured': sorted(captured), 'provider': 'offline deterministic fixture; no remote model calls'}
(evidence / 'calm-capture-result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps(result))
sys.exit(child.returncode)
