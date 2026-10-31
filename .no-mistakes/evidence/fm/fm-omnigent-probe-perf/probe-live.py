from __future__ import annotations
import json, os, pathlib, signal, subprocess, tempfile, time, urllib.request, uuid
ROOT = pathlib.Path.cwd()
SERVER = 'http://127.0.0.1:52131'
EVIDENCE = pathlib.Path('/Users/davidtandoh/.no-mistakes/evidence/01M68FVN66AFDRZ852VHX56JNS')
report = {'server': SERVER, 'checks': []}
def fetch(path):
    with urllib.request.urlopen(SERVER + path, timeout=5) as response:
        body = response.read(4*1024*1024+1)
    if len(body)>4*1024*1024: raise RuntimeError('response exceeds inspection bound')
    return json.loads(body),len(body)
def run(command, env):
    started = time.monotonic()
    p = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    timeout = False
    try: out,err = p.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        timeout=True
        os.killpg(p.pid,signal.SIGKILL)
        out,err=p.communicate()
    return {'elapsed_ms':round((time.monotonic()-started)*1000), 'exit':p.returncode, 'timeout':timeout, 'stdout':out.decode().strip(), 'stderr':err.decode().strip()}
def check(label, meta, expected, size=None, backend=False):
    env=dict(os.environ, TMPDIR=str(tmp))
    command=['bash',str(ROOT/'bin/fm-omnigent.sh'),'probe',str(meta)]
    if backend:
        command=['bash','-c','. bin/fm-backend.sh; fm_backend_omnigent_agent_state alive "$1"','_',str(meta)]
    result=run(command,env)
    result.update(name=label,expected=expected,response_bytes=size,pass_=False)
    result['pass_']=result['exit']==0 and result['stdout']==expected and not result['timeout']
    result['leftover_probe_files']=len(list(tmp.glob('fm-omnigent-probe.*')))
    result['pass_'] &= result['leftover_probe_files']==0
    report['checks'].append(result)
    print(json.dumps(result,sort_keys=True),flush=True)
try:
    with tempfile.TemporaryDirectory(prefix='.probe-live-',dir=ROOT) as directory:
        tmp=pathlib.Path(directory)
        rows,_=fetch('/v1/sessions?limit=100')
        selected={}
        for row in rows['data']:
            data,size=fetch('/v1/sessions/'+row['id'])
            dead=data.get('archived') is True or data.get('status')=='failed' or data.get('runner_online') is False
            kind='dead' if dead else 'alive' if data.get('runner_online') is True else 'unknown'
            if kind not in ('alive','dead') or kind in selected: continue
            if size < 131080: continue
            meta=tmp/(kind+'.meta')
            meta.write_text('omnigent=on\nomnigent_session='+row['id']+'\nomnigent_server='+SERVER+'\n')
            selected[kind]=(meta,size)
            if len(selected)==2: break
        report['large_records_found']=sorted(selected)
        for kind,(meta,size) in selected.items():
            for repetition in range(3): check('large real '+kind+' record probe '+str(repetition+1),meta,kind,size)
            check('supervision backend with large real '+kind+' record',meta,kind,size,backend=True)
        absent=tmp/'missing.meta'
        absent.write_text('omnigent_session='+uuid.uuid4().hex+'\nomnigent_server='+SERVER+'\n')
        check('nonexistent session returns dead',absent,'dead')
        empty=tmp/'unbound.meta'; empty.write_text('harness=codex\n')
        check('unbound task returns unknown',empty,'unknown')
        check('unbound task preserves alive pane verdict',empty,'alive',backend=True)
        if 'alive' in selected:
            meta,size=selected['alive']
            base=ROOT/'bin/.probe-baseline-test.sh'
            try:
                base.write_bytes(subprocess.check_output(['git','show','6694b71bb6925f1d2ad19c4a9306979f583f400c:bin/fm-omnigent.sh']))
                result=run(['bash',str(base),'probe',str(meta)],dict(os.environ,TMPDIR=str(tmp)))
                report['baseline_large_alive']=result
                print('BASELINE '+json.dumps(result,sort_keys=True),flush=True)
            finally: base.unlink(missing_ok=True)
finally:
    (EVIDENCE/'probe-live.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
