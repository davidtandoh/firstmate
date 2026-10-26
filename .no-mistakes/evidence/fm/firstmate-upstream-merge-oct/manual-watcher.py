import os, pathlib, subprocess, tempfile, shutil, threading, re
lab=pathlib.Path(tempfile.mkdtemp(prefix='.test-watcher-',dir=str(pathlib.Path.cwd())))
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','CLAUDE_PID','CLAUDE_CODE_SESSION'))}
env.update(FM_HOME=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
def run(args,code=0):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    print('$',' '.join(args),'\nexit=',p.returncode,'\n'+p.stdout+p.stderr,flush=True)
    assert p.returncode==code
    return p.stdout+p.stderr
try:
    run(['bash','bin/fm-lab-home.sh','create',str(lab)])
    run(['bash','bin/fm-watch-checkpoint.sh','--seconds','1'],124)
    assert not (lab/'state/.watch.lock/pid').exists()
    print('Quiet checkpoint returned control and released its process lock.',flush=True)
    recovery=run(['bash','bin/fm-wake-drain.sh'])
    ack=re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)',recovery)
    if ack:
        run(['bash','bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]])
    t=threading.Timer(1,lambda:(lab/'state/demo.status').write_text('done: manual watcher acceptance\n'))
    t.start()
    out=run(['bash','bin/fm-watch-checkpoint.sh','--seconds','8'])
    t.join()
    assert 'signal:' in out
    drained=run(['bash','bin/fm-wake-drain.sh'])
    assert '\tsignal\tdemo.status\t' in drained
    assert 'manual watcher acceptance' in drained
    print('A later completed task surfaced through the real watcher and durable drain after a quiet checkpoint.',flush=True)
finally:
    shutil.rmtree(lab)
    print('Disposable home removed.',flush=True)
