import os, pathlib, tempfile, shutil, subprocess, json, hashlib
root=pathlib.Path.cwd()
evidence=pathlib.Path('/Users/davidtandoh/.no-mistakes/evidence/01M6B8YQ847HW4RDWF30TF0SAS')
home=pathlib.Path(tempfile.mkdtemp(prefix='.ask-live-', dir=root))
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(k)
env['FM_HOME']=str(home)
def run(args, expected=0, cwd=root, input_text=None):
    print('$ '+ ' '.join(str(a) for a in args), flush=True)
    p=subprocess.run([str(a) for a in args],cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,input=input_text)
    print(p.stdout, end='', flush=True)
    print('exit='+str(p.returncode), flush=True)
    assert p.returncode==expected,(args,p.returncode,expected)
    return p.stdout
ask=root/'bin/fm-ask.sh'
hold=root/'bin/fm-captain-hold.sh'
def openask(task,kind,q,*extra,expected=0):
    return run([ask,'open','--task',task,'--kind',kind,'--question',q,*extra],expected)
def records():
    return {p.stem:json.loads(p.read_text()) for p in (home/'state/captain-asks').glob('*.json')}
def snapshot(name):
    data=records()
    (evidence/name).write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps(data,indent=2),flush=True)
try:
    run([root/'bin/fm-lab-home.sh','create',home])
    shutil.copyfile(root/'.tasks.toml',home/'.tasks.toml')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    run(['tasks-axi','add','GB-hook-1031','Live ask validation','--kind','ship','--repo','sample'],cwd=home)
    run([hold,'hold','GB-hook-1031','--reason','Approval needed'])
    args=('--option','A=Ship the records','--option','B=Wait','--recommend','A','--reason','This unblocks alerts.','--link','https://example.com/pr/7')
    openask('GB-hook-1031','decision','Which approach ships?',*args)
    before=(home/'state/captain-asks/gb-hook-1031-decision-1.json').read_bytes()
    openask('GB-hook-1031','decision','Which approach ships?',*args)
    assert before==(home/'state/captain-asks/gb-hook-1031-decision-1.json').read_bytes()
    openask('GB-hook-1031','approval','Merge the fix?')
    openask('other','blocker','The token expired.','--key','other-blocker')
    for p in (home/'state/captain-asks').glob('*.json'):
        assert p.stat().st_mode & 0o777 == 0o600
    snapshot('live-open-records.json')
    for q in ('Merge <https://github.com/example/repo/pull/7>?','Merge *now*?','1. Merge now?','Merge the fix? Restart the relay?'):
        prior=records()
        openask('bad','decision',q,expected=1)
        assert records()==prior
    decision=home/'decision.txt'
    decision.write_text('Proceed.\n')
    run([hold,'answer','GB-hook-1031','--decision-file',decision,'--release'])
    assert records()['gb-hook-1031-decision-1']['state']=='answered'
    assert records()['gb-hook-1031-approval-1']['state']=='answered'
    assert records()['other-blocker']['state']=='open'
    openask('GB-hook-1031','decision','Which approach ships?',*args,expected=3)
    openask('GB-hook-1031','approval','Proceed with follow-up?')
    run([hold,'answer','GB-hook-1031','--decision-file',decision,'--release'],expected=1)
    assert records()['gb-hook-1031-approval-2']['state']=='open'
    run([hold,'hold','GB-hook-1031','--reason','Follow-up approval needed'])
    openask('GB-hook-1031','approval','Approve new hold?')
    run([hold,'answer','GB-hook-1031','--decision-file',decision,'--release'])
    assert records()['gb-hook-1031-approval-3']['state']=='answered'
    run(['tasks-axi','add','keyed-task','Keyed answer validation','--kind','ship','--repo','sample'],cwd=home)
    run([hold,'hold','keyed-task','--reason','Keyed approval needed'])
    openask('keyed-task','approval','Proceed with keyed task?')
    run([hold,'answers','--source','live CLI validation'],input_text='keyed-task\tgo\tProceed\trelease\n')
    assert records()['keyed-task-approval-1']['state']=='answered'
    run(['tasks-axi','add','retry-task','Closure retry validation','--kind','ship','--repo','sample'],cwd=home)
    run([hold,'hold','retry-task','--reason','Retry approval needed'])
    openask('retry-task','approval','Proceed with retry task?')
    broken=home/'state/captain-asks/broken.json'
    broken.write_text('{not json')
    run([hold,'answer','retry-task','--decision-file',decision,'--release'],expected=1)
    assert json.loads((home/'state/captain-asks/retry-task-approval-1.json').read_text())['state']=='open'
    broken.unlink()
    run([hold,'answer','retry-task','--decision-file',decision,'--release'])
    assert records()['retry-task-approval-1']['state']=='answered'
    for target in ('option','reason'):
        extra=['--option','A=Merge <https://example.com/pr/7>?'] if target=='option' else ['--option','A=Proceed','--recommend','A','--reason','Merge *now*.']
        prior=records()
        openask('bad','decision','Proceed?',*extra,expected=1)
        assert records()==prior
    openask('plain','decision','Use the snake_case identifier.')
    run([ask,'close','other-blocker','--withdrawn'])
    snapshot('live-closed-records.json')
    print('LIVE CLI SCENARIOS PASSED',flush=True)
finally:
    shutil.rmtree(home)
