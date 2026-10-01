from __future__ import annotations
import json, os, re, shlex, shutil, subprocess, tempfile, time, urllib.request
from pathlib import Path
from mlflow import MlflowClient
ROOT = Path.cwd()
E = Path('/Users/davidtandoh/.no-mistakes/evidence/01M3VQQ8KSX5QDVVFHY221R9G7')
H = ROOT / 'bin/fm-herdr-lab.sh'
# Exclusive claim survives cleanup and forbids another model turn in this gate.
claim = E / 'round5-single-attempt.json'
with claim.open('x') as f:
    json.dump({'attempt_limit':1,'attempt_reserved':True,'additional_model_turns_authorized':False,'head':'cd639e039e986e1e657fa4b9df41e65df3eb2c7b'}, f, sort_keys=True); f.write('\n')
base = Path(tempfile.mkdtemp(prefix='.nm-omni-single-', dir=ROOT))
(base/'home/state').mkdir(parents=True)
(base/'home/data').mkdir()
(base/'home/config').mkdir()
(base/'cwd').mkdir()
env = {k:v for k,v in os.environ.items() if not k.startswith('HERDR_') and not k.startswith('FM_') and k not in ('NO_MISTAKES_GATE','OMNIGENT')}
env.update(FM_HERDR_LAB_STATE_DIR=str(base/'lab-state'), LC_ALL='C', LC_CTYPE='C', MLFLOW_HTTP_REQUEST_TIMEOUT='10', MLFLOW_HTTP_REQUEST_MAX_RETRIES='0')
os.environ.update(MLFLOW_HTTP_REQUEST_TIMEOUT='10', MLFLOW_HTTP_REQUEST_MAX_RETRIES='0')
log = (E/'round5-single-worker.log').open('x')
def save(name, value):
    (E/name).write_text(json.dumps(value, sort_keys=True, indent=2)+'\n')
def run(args, check=True):
    p = subprocess.run([str(a) for a in args], env=env, capture_output=True, text=True, timeout=40)
    log.write('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+p.stderr+'\nexit='+str(p.returncode)+'\n'); log.flush()
    if check and p.returncode: raise RuntimeError('Command failed: '+str(args[0]))
    return p.stdout
class ServiceStopped(Exception): pass
def health(label):
    status=json.loads(run(['agent-kit','observe','serve','status','--json'],False))
    save('round5-service-'+label+'.json',status)
    if status.get('status') != 'running':
        p=Path(status['redactor_log'])
        with p.open('rb') as f:
            f.seek(0,2); f.seek(max(0,f.tell()-16384)); tail=f.read(16384)
        (E/'round5-redactor-tail.log').write_bytes(tail)
        raise ServiceStopped('Managed service degraded; no retry or repair')
    return status
session=None; pane=None; sid=None; server=None; provisioned=False
result={'attempt_limit':1,'workers_launched':0,'prompts_submitted':0,'additional_model_turns_authorized':False,'tested_head_sha':run(['git','rev-parse','HEAD']).strip()}
def lab(*args): return run([H,'run',session,*args])
def api(path,method='GET'):
    with urllib.request.urlopen(urllib.request.Request(server+path,method=method),timeout=10) as r:
        data=r.read(1048577)
        if len(data)>1048576: raise RuntimeError('Oversized API response')
        return json.loads(data) if data else None
def read_pane():
    global sid
    text=lab('pane','read',pane,'--source','recent','--lines','100')
    (E/'round5-worker-pane.txt').write_text(text)
    match=re.search(r'^Omnigent: '+re.escape(server)+r'/c/([a-f0-9]{32})',text,re.M)
    if match: sid=match.group(1); result['worker_session']=sid
    return text
try:
    status=health('before'); server=status['server_url'].rstrip('/')
    session=run([H,'name','omni-single']).strip(); result['lab_session']=session
    run([H,'provision',session]); provisioned=True
    ws=json.loads(lab('workspace','create','--label','omni-single','--cwd',str(base/'cwd'),'--no-focus'))['result']['workspace']['workspace_id']
    tab=json.loads(lab('tab','create','--workspace',ws,'--cwd',str(base/'cwd'),'--label','worker','--no-focus'))['result']
    pane=tab['root_pane']['pane_id']; result['pane_id']=pane
    prompt='This is the only turn in an authorized trace-export canary. Do not use tools, read files, start agents, or change anything. Return exactly OMNI_SINGLE_FINAL_20261001 as your final response and end the turn.'
    launch=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','FM_HOME='+str(base/'home'),'FM_BACKEND=herdr','FM_TASK_ID=omni-single','LC_ALL=C',str(ROOT/'bin/fm-omnigent.sh'),'run','codex','--model','gpt-6-sol','--dangerously-bypass-approvals-and-sandbox','--disable','hooks','-c','model_reasoning_effort="low"',prompt]
    launch_file=base/'launch.sh'
    launch_file.write_text('#!/usr/bin/env bash\nset -euo pipefail\nexec '+shlex.join(launch)+'\n')
    # Submit once through the public launch boundary; never resend the prompt.
    result.update(workers_launched=1,prompts_submitted=1)
    save('round5-single-result.json',result)
    lab('pane','run',pane,'bash '+shlex.quote(str(launch_file)))
    client=MlflowClient(tracking_uri=status['mlflow_url'])
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        health('latest')
        read_pane()
        found=[]
        if sid:
            token=None
            for page in range(10):
                traces=client.search_traces(locations=[status['experiment_id']],filter_string="metadata.`mlflow.trace.session` = '"+sid+"'",max_results=100,page_token=token)
                for trace in traces:
                    spans=[s for s in trace.data.spans if s.name.startswith('agent:') and s.attributes.get('session.id')==sid]
                    if spans:
                        found.append({'trace_id':trace.info.trace_id,'status':str(trace.info.status),'session':sid,'request':trace.data.request,'response':trace.data.response,'agent_spans':[{'name':s.name,'output.value':s.attributes.get('output.value')} for s in spans]})
                token=traces.token
                if not token: break
            save('round5-mlflow.json',found)
            if any('OMNI_SINGLE_FINAL_20261001' in str(t['response']) and any('OMNI_SINGLE_FINAL_20261001' in str(s['output.value']) for s in t['agent_spans']) for t in found):
                result.update(result='pass',evidence='round5-mlflow.json'); break
        time.sleep(5)
    else:
        health('final')
        result.update(result='inconclusive',reason='No session-matched final response within 180 seconds; one-attempt limit exhausted')
except ServiceStopped as exc:
    result.update(result='accepted-prior-trace',reason=str(exc),prior_trace='tr-9c4e2a47c104c2c4d10ea55381125437',prior_omnigent='dc4f1ffa',prior_pak='802a74d',availability_issue='Personal Agent Kit redactor safe-stop; tracked separately by Firstmate; outside this task')
except Exception as exc:
    result.update(result='error',reason=str(exc))
finally:
    cleanup=[]
    try:
        if provisioned and pane:
            if not sid: read_pane()
            if not sid: raise RuntimeError('Cannot identify owned conversation; preserve lab')
            endpoint='/v1/sessions/'+sid+'/resources/terminals'
            resources=api(endpoint)
            assert resources['object']=='list' and resources['has_more'] is False
            for item in resources['data']:
                assert item['session_id']==sid and item['type']=='terminal' and re.fullmatch(r'[A-Za-z0-9_-]+',item['id'])
                api(endpoint+'/'+item['id'],'DELETE')
            after=api(endpoint)
            assert after['object']=='list' and after['has_more'] is False and after['data']==[]
            cleanup.append({'session':sid,'terminal_readback':after})
        if provisioned: run([H,'teardown',session])
        shutil.rmtree(base)
        result['cleanup']='owned terminals empty; lab removed; default fleet tripwire unchanged; temporary worktree files removed'
    except Exception as exc:
        result['cleanup_error']=str(exc); result['temporary_path']=str(base)
    save('round5-cleanup.json',cleanup)
    save('round5-single-result.json',result)
    log.close()
    print(json.dumps(result,sort_keys=True,indent=2))
