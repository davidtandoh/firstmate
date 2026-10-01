from __future__ import annotations
import json, os, re, shlex, shutil, subprocess, tempfile, time, urllib.request
from pathlib import Path
ROOT = Path.cwd()
E = Path('/Users/davidtandoh/.no-mistakes/evidence/01M3VQQ8KSX5QDVVFHY221R9G7')
H = str(ROOT / 'bin/fm-herdr-lab.sh')
env = {k:v for k,v in os.environ.items() if not k.startswith('HERDR_') and not (k.startswith('FM_') and k.endswith('_OVERRIDE')) and k not in ('FM_HOME','FM_GATE_REFUSE_BYPASS','NO_MISTAKES_GATE','FM_TASK_ID','OMNIGENT','FM_OMNIGENT')}
env['LC_ALL']='C'
log = (E/'r2-primary-worker.log').open('w')
def run(args, check=True, timeout=30, custom=None):
    p=subprocess.run([str(a) for a in args], env=custom or env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n'); log.flush()
    if check and p.returncode: raise RuntimeError('Command failed: '+str(args[0]))
    return p.stdout
session=run([H,'name','omni-round2']).strip()
def lab(*args): return run([H,'run',session,*args])
base=Path(tempfile.mkdtemp(prefix='.nm-omni-r2-', dir=ROOT))
home=base/'home'; tools=base/'tools'; tools.mkdir()
owned=[]; provisioned=False
server=json.loads(run([ROOT/'bin/fm-omnigent.sh','run','--dry-run','codex']))['server_url'].rstrip('/')
def api(path, method='GET'):
    with urllib.request.urlopen(urllib.request.Request(server+path,method=method),timeout=10) as r:
        body=r.read(1048576)
        return json.loads(body) if body else None
def pane_text(pane): return lab('pane','read',pane,'--source','recent','--lines','100')
def capture_session(pane):
    text=pane_text(pane)
    match=re.search(r'^Omnigent: '+re.escape(server)+r'/c/([a-f0-9]{32})',text,re.M)
    return match.group(1) if match else None
try:
    run([ROOT/'bin/fm-lab-home.sh','create',home])
    run([H,'provision',session]); provisioned=True
    # Every child Herdr call uses the guarded helper; this forwards real calls.
    shim='#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\ni=a.index("--session")\ns=a[i+1]\nassert s=='+repr(session)+'\ndel a[i:i+2]\nos.environ["PATH"]='+repr(env['PATH'])+'\nos.execv('+repr(H)+',['+repr(H)+',"run",s]+a)\n'
    (tools/'herdr').write_text(shim); (tools/'herdr').chmod(0o755)
    scoped=dict(env, FM_HOME=str(home), FM_BACKEND='herdr', PATH=str(tools)+':'+env['PATH'])
    project=base/'project'; worker=base/'worker'
    run(['git','init','-q',project])
    run(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','core.hooksPath=/dev/null','commit','--allow-empty','-qm','Initialize lab'])
    run(['git','-C',project,'worktree','add','-q','-b','lab-worker',worker])
    ws=json.loads(lab('workspace','create','--label','omni-round2','--cwd',str(ROOT),'--no-focus'))['result']['workspace']['workspace_id']
    def tab(label,cwd):
        result=json.loads(lab('tab','create','--workspace',ws,'--cwd',str(cwd),'--label',label,'--no-focus'))['result']
        pane=result['root_pane']['pane_id']; owned.append(pane)
        return pane,result['tab']['tab_id']
    primary,ptab=tab('primary',ROOT)
    wp,wt=tab('worker',worker)
    def meta(name,pane,tid,cwd,proj):
        (home/'state'/ (name+'.meta')).write_text('\n'.join(['window='+session+':'+pane,'endpoint_task_id='+name,'worktree='+str(cwd),'project='+str(proj),'harness=codex','kind=scout','mode=scout','yolo=off','backend=herdr','herdr_session='+session,'herdr_workspace_id='+ws,'herdr_tab_id='+tid,'herdr_pane_id='+pane])+'\n')
    meta('probe-primary',primary,ptab,ROOT,project)
    meta('probe-worker',wp,wt,worker,project)
    probe=base/'worker-probe.sh'
    probe.write_text('#!/usr/bin/env bash\nset -euo pipefail\nprintf "OMNIGENT=%s FM_OMNIGENT=%s FM_BACKEND=%s FM_TASK_ID=%s\\n" "${OMNIGENT-}" "${FM_OMNIGENT-}" "${FM_BACKEND-}" "${FM_TASK_ID-}" > '+shlex.quote(str(E/'r2-worker-observed.txt'))+'\n[ "$OMNIGENT" = 1 ]\n[ "$FM_OMNIGENT" = on ]\n[ "$FM_TASK_ID" = probe-worker ]\nprintf "OMNIGENT=%s FM_OMNIGENT=%s FM_BACKEND=%s FM_TASK_ID=%s\\n" "$OMNIGENT" "$FM_OMNIGENT" "${FM_BACKEND-}" "$FM_TASK_ID" > '+shlex.quote(str(E/'r2-worker-env.txt'))+'\n')
    run([ROOT/'bin/fm-brief.sh','probe-worker',str(project),'--scout','--herdr-lab'],custom=scoped)
    brief=home/'data/probe-worker/brief.md'
    s=brief.read_text().replace('{TASK}','Validate the wrapped worker environment and produce a final response for MLflow acceptance.').replace('{FIRSTMATE_SPEC}','This is a bounded runtime canary. Run bash '+str(probe)+'. Do not change source, configuration, credentials, or Git state. Do not run any pipeline. Return exactly OMNI_R2_WORKER_FINAL. The test driver owns cleanup. End after this request.')
    brief.write_text(s)
    action=base/'primary-action.sh'
    action.write_text('#!/usr/bin/env bash\nset -euo pipefail\n[ "$OMNIGENT" = 1 ]\n[ "$FM_OMNIGENT" = on ]\n[ "$FM_BACKEND" = herdr ]\nprintf "OMNIGENT=%s FM_OMNIGENT=%s FM_BACKEND=%s\\n" "$OMNIGENT" "$FM_OMNIGENT" "$FM_BACKEND" > '+shlex.quote(str(E/'r2-primary-env.txt'))+'\nenv -u FM_OMNIGENT '+shlex.quote(str(ROOT/'bin/fm-spawn.sh'))+' probe-worker --relaunch --harness codex --model gpt-6-sol --effort low > '+shlex.quote(str(E/'r2-spawn.log'))+' 2>&1\nprintf "spawn-complete\\n" > '+shlex.quote(str(base/'spawn-complete'))+'\n')
    # Use the native primary launch boundary with explicit test sandbox posture.
    # The separate start attempt proved startup and FM_BACKEND, but its native
    # sandbox correctly refused the external evidence path.
    launch=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','FM_HOME='+str(home),'FM_BACKEND=herdr','PATH='+scoped['PATH'],str(ROOT/'bin/fm-omnigent.sh'),'run','codex','--model','gpt-6-sol','--dangerously-bypass-approvals-and-sandbox','--disable','hooks','-c','model_reasoning_effort="low"','']
    launch_file=base/'primary-launch.sh'
    launch_file.write_text('#!/usr/bin/env bash\nset -euo pipefail\nexec '+shlex.join(launch)+'\n')
    lab('pane','run',primary,'bash '+shlex.quote(str(launch_file)))
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        text=pane_text(primary)
        if '›' in text: break
        time.sleep(2)
    else: raise RuntimeError('Primary did not reach a visible composer')
    (E/'r2-primary-start.txt').write_text(text)
    prompt='This is an authorized, bounded live test in a disposable marked lab home. Do exactly one shell action: bash '+str(action)+'. That script launches one test worker through Firstmate. Do not start any watcher or other agent, do not change source or configuration, and do not run any no-mistakes pipeline. After the command finishes, return OMNI_R2_PRIMARY_FINAL and stop. The test driver owns cleanup.'
    lab('pane','send-text',primary,prompt); time.sleep(1); lab('pane','send-keys',primary,'enter')
    deadline=time.monotonic()+240
    while time.monotonic()<deadline:
        if (base/'spawn-complete').exists() and (E/'r2-worker-env.txt').exists() and (home/'state/probe-worker.turn-ended').exists(): break
        time.sleep(3)
    (E/'r2-primary-pane.txt').write_text(pane_text(primary))
    (E/'r2-worker-pane.txt').write_text(pane_text(wp))
    (E/'r2-worker-meta.txt').write_text((home/'state/probe-worker.meta').read_text())
    observations={'spawn_complete':(base/'spawn-complete').exists(),'worker_environment':(E/'r2-worker-env.txt').exists(),'turn_end':(home/'state/probe-worker.turn-ended').exists(),'primary_session':capture_session(primary),'worker_session':capture_session(wp)}
    (E/'r2-primary-worker-result.json').write_text(json.dumps(observations,sort_keys=True,indent=2)+'\n')
    if not all(observations[k] for k in ('spawn_complete','worker_environment','turn_end')): raise RuntimeError('Primary/worker journey incomplete; inspect panes and spawn output')
    for name in ('probe-worker','probe-primary'):
        run([ROOT/'bin/fm-control.sh',name,'exit'],custom=scoped,timeout=40)
finally:
    cleanup=[]
    if provisioned:
        for pane in owned:
            sid=capture_session(pane)
            if not sid: continue
            endpoint='/v1/sessions/'+sid+'/resources/terminals'
            resources=api(endpoint)
            assert resources['has_more'] is False
            for item in resources['data']:
                assert item['session_id']==sid and item['type']=='terminal'
                api(endpoint+'/'+item['id'],'DELETE')
            after=api(endpoint); cleanup.append({'session':sid,'terminals':after})
            assert after['data']==[]
        run([H,'teardown',session])
    (E/'r2-primary-worker-cleanup.json').write_text(json.dumps(cleanup,sort_keys=True,indent=2)+'\n')
    shutil.rmtree(base)
    log.close()
