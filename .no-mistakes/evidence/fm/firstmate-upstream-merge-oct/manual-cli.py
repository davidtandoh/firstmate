import os, pathlib, subprocess, tempfile, shutil, resource, json, hashlib
root = pathlib.Path.cwd()
lab = pathlib.Path(tempfile.mkdtemp(prefix='.test-cli-', dir=str(root)))
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'OMNIGENT', 'CLAUDE_CODE_SESSION', 'CLAUDE_PID'))}
env['FM_HOME'] = str(lab)
def run(args, expected=0, limited=False):
    def limit(): resource.setrlimit(resource.RLIMIT_NOFILE, (64,64))
    p = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=limit if limited else None, timeout=30)
    print('$', ' '.join(map(str,args)), '\nexit=',p.returncode,'\n',p.stdout, flush=True)
    assert p.returncode == expected, p.stdout
    return p.stdout
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    output = lab/'export'
    # Export root must be disjoint from its home.
    home = lab/'home'
    for d in ('config','state','data'): (home/d).mkdir(parents=True)
    env['FM_HOME'] = str(home)
    (home/'config/record-export-root').write_text(str(output)+'\n')
    (home/'state/task-a.inbox/handled').mkdir(parents=True)
    (home/'state/task-a.meta').write_text('spawn_gen=manual\n')
    for n in range(150):
        task=home/'data'/('task-'+str(n)); task.mkdir()
        for f in ('brief.md','report.md'): (task/f).write_text(f+' '+str(n)+'\n')
        (home/'state/task-a.inbox/handled'/('%03d.msg'%n)).write_text('message '+str(n)+'\n')
    run(['bash','bin/fm-record-export.sh','sync'],limited=True)
    run(['bash','bin/fm-record-export.sh','archive-task','task-a'],limited=True)
    for f in (home/'data').glob('*/*'):
        assert (output/'live/data'/f.parent.name/f.name).read_bytes() == f.read_bytes()
    manifest=json.loads((output/'archive/task-a/manual/manifest.v1.json').read_text())
    assert len(manifest['files']) == 151
    for f in (home/'state/task-a.inbox/handled').iterdir():
        assert (output/'archive/task-a/manual/inbox/handled'/f.name).read_bytes() == f.read_bytes()
    print('Verified 300 live documents and 150 archived messages byte-for-byte with RLIMIT_NOFILE=64.',flush=True)
    env['FM_HOME'] = str(lab)
    (lab/'config/omnigent').write_text('on\n')
    project=lab/'projects/demo'; project.mkdir()
    out=run(['bash','bin/fm-spawn.sh','manual-refusal',str(project),'claude','--scout','--backend','t3code'],expected=1)
    assert 'omnigent=on conflicts with backend=t3code' in out
    assert not (lab/'state/manual-refusal.meta').exists()
    assert list(project.iterdir()) == []
    print('Verified Omnigent/T3 conflict refused with no worker metadata or project allocation.',flush=True)
finally:
    shutil.rmtree(lab)
    print('Disposable home removed.',flush=True)
