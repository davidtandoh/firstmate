from __future__ import annotations
import json, os, pathlib, shutil, signal, subprocess, tempfile, time
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('/Users/davidtandoh/.no-mistakes/evidence/01M49GR5XDASFZZ5JK8HARH36F')
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) and k not in ('STATE','TMUX','OMNIGENT')}
ENV.update(LC_ALL='C', LANG='C', FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_GUARD_GRACE='2', FM_ARM_ATTACH_POLL='0.1')

def wait_until(predicate, limit, description):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.1)
    raise RuntimeError('deadline: ' + description)

def scenario(name, stall):
    lab = pathlib.Path(tempfile.mkdtemp(prefix='.fm-watcher-live-', dir=str(ROOT)))
    env = dict(ENV, FM_HOME=str(lab), FM_WATCHER_STALL_BOUND=str(stall))
    processes, streams = [], []
    watcher = None
    record = {'scenario': name, 'live': True, 'lab':str(lab), 'hard_stall_seconds':stall}
    def run(*args):
        p = subprocess.run([str(ROOT/'bin'/args[0]), *args[1:]], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        record.setdefault('commands', []).append({'argv':list(args),'exit_code':p.returncode,'output':p.stdout})
        if p.returncode: raise RuntimeError(p.stdout)
        return p.stdout
    def start(label, extra=None):
        path=EVIDENCE/(name+'-'+label+'.log')
        stream=path.open('w'); streams.append(stream)
        p=subprocess.Popen([str(ROOT/'bin/fm-watch-arm.sh')],env=dict(env,**(extra or {})),stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        processes.append(p)
        return p,path
    try:
        run('fm-lab-home.sh','create',str(lab))
        owner, ownerlog = start('owner')
        wait_until(lambda: 'watcher: started' in ownerlog.read_text(), 15, 'watcher start')
        watcher=int((lab/'state/.watch.lock/pid').read_text())
        attached, attachlog = start('attached', {'FM_ARM_CONFIRM_TIMEOUT':'1'})
        wait_until(lambda: 'watcher: attached' in attachlog.read_text(), 10, 'arm attachment')
        os.kill(watcher,signal.SIGSTOP)
        frozen=time.monotonic()
        if stall > 10:
            wait_until(lambda: time.monotonic()-frozen >= 7, 9, 'slow cycle interval')
            record['suspended_seconds']=round(time.monotonic()-frozen,2)
            record['attached_exit_while_frozen']=attached.poll()
            assert attached.poll() is None, attachlog.read_text()
            assert 'FAILED' not in attachlog.read_text(), attachlog.read_text()
            note=run('fm-inbox.sh','note','--request-id','live-slow-cycle','--json','Wake after the delayed watcher resumes')
            os.kill(watcher,signal.SIGCONT)
            assert owner.wait(timeout=20)==0, ownerlog.read_text()
            assert attached.wait(timeout=15)==0, attachlog.read_text()
            assert 'check:' in attachlog.read_text(), attachlog.read_text()
            assert 'FAILED' not in attachlog.read_text(), attachlog.read_text()
            run('fm-inbox.sh','list')
            run('fm-wake-drain.sh')
        else:
            rc=attached.wait(timeout=15)
            record['attached_exit_at_stall']=rc
            assert rc != 0 and 'stalled (beacon' in attachlog.read_text(), attachlog.read_text()
            os.kill(watcher,signal.SIGCONT)
        for filename in ('.watch-cycle-exits.log','.wake-queue'):
            source=lab/'state'/filename
            if source.is_file():
                shutil.copyfile(source,EVIDENCE/(name+filename+'.txt'))
        record['result']='pass'
    except Exception as exc:
        record.update(result='fail',error=str(exc))
    finally:
        if watcher:
            try: os.kill(watcher,signal.SIGCONT)
            except ProcessLookupError: pass
        try: run('fm-watch-arm.sh','--stop')
        except Exception as exc: record['cleanup_error']=str(exc)
        for p in processes:
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
        for stream in streams: stream.close()
        shutil.rmtree(lab)
        record['lab_removed']=not lab.exists()
        (EVIDENCE/(name+'.json')).write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
        print(json.dumps(record,sort_keys=True))
    return record['result']=='pass' and not record.get('cleanup_error')

ok=scenario('watcher-slow-cycle',60)
if ok: ok=scenario('watcher-hard-stall',5)
raise SystemExit(0 if ok else 1)
