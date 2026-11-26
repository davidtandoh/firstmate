import os, pathlib, subprocess, json, tempfile, shutil
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-test-live-',dir=str(root)))
# Mark only an empty home, using the supported helper.
lab.rmdir()
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','OMNIGENT','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(k,None)
env.update(FM_HOME=str(lab),TREEHOUSE_ROOT=str(lab/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
def run(args,cwd=root,check=True):
    p=subprocess.run([str(x) for x in args],cwd=str(cwd),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print('$', ' '.join(map(str,args)), '\n'+p.stdout+'exit='+str(p.returncode),flush=True)
    if check and p.returncode: raise RuntimeError(args)
    return p
results=[]
try:
    run(['bin/fm-lab-home.sh','create',lab])
    for variant in ['generated','modified','timeout','moved-event','other']:
        proj=lab/'projects'/variant; proj.mkdir()
        run(['git','init','-q','-b','main'],proj)
        (proj/'.gitignore').write_text('.claude/\n')
        run(['git','add','.gitignore'],proj)
        run(['git','commit','-q','-m','Initialize lab'],proj)
        p=run(['treehouse','get','--lease','--no-fetch','--json'],proj)
        allocation=json.loads(next(line for line in p.stdout.splitlines() if line.startswith("{parsed-never") or line.startswith("{\"path\"")))
        print('allocation', allocation,flush=True)
        # JSON is the real Treehouse allocation protocol.
        wt=pathlib.Path(allocation.get('path') or allocation.get('worktree_path') or allocation.get('worktree'))
        command="'/fm/bin/fm-busy-event.sh' apply '/fm/state' 'live-hooks' idle --gen 'g1' --source claude-hook --event session-end 2>/dev/null || true"
        hooks={'SessionEnd':[{'hooks':[{'type':'command','command':command}]}]}
        (wt/'.claude').mkdir(exist_ok=True); (wt/'.codex').mkdir()
        (wt/'.claude/settings.local.json').write_text(json.dumps({'hooks':hooks}))
        copy=json.loads(json.dumps(hooks))
        if variant=='modified': copy['SessionEnd'][0]['hooks'][0]['command']+='; curl example.invalid'
        if variant=='timeout': copy['SessionEnd'][0]['hooks'][0]['timeout']=60
        if variant=='moved-event': copy['Stop']=copy.pop('SessionEnd')
        target=wt/'.codex/hooks.json'; target.write_text(json.dumps({'hooks':copy})); before=target.read_bytes()
        if variant=='other': (wt/'notes.txt').write_text('Unlanded work\n')
        (lab/'state/live-hooks.meta').write_text(f'worktree={wt}\nproject={proj}\nkind=ship\nmode=local-only\nharness=codex\n')
        (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
        run(['tasks-axi','add','live-hooks','Hook cleanup lab','--kind','ship','--file',lab/'data/backlog.md'])
        run(['tasks-axi','start','live-hooks','--file',lab/'data/backlog.md'])
        p=run(['bin/fm-teardown.sh','live-hooks','--legacy-record'],check=False)
        passed=(p.returncode==0 and not target.exists()) if variant=='generated' else (p.returncode==1 and 'REFUSED:' in p.stdout and target.read_bytes()==before)
        print('OBSERVED',json.dumps({'variant':variant,'exit':p.returncode,'hooks_exist':target.exists(),'pass':passed}),flush=True)
        results.append({'variant':variant,'pass':passed})
        if not passed: break
finally:
    shutil.rmtree(lab)
    print('RESULTS',json.dumps(results),flush=True)
