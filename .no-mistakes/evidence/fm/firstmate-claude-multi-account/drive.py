import json, os, signal, subprocess, sys, time
from pathlib import Path
root=Path(__file__).parent
label=sys.argv[1]
budget=int(sys.argv[2])
command=sys.argv[3:]
start=time.monotonic()
with (root/(label+'.log')).open('w') as log:
    log.write('$ '+ ' '.join(command)+'\n'); log.flush()
    proc=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        code=proc.wait(timeout=budget)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid,signal.SIGTERM)
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: os.killpg(proc.pid,signal.SIGKILL); proc.wait()
        code=124
    elapsed=round((time.monotonic()-start)*1000)
    log.write('\nexit='+str(code)+' duration_ms='+str(elapsed)+'\n')
text=(root/(label+'.log')).read_text()
result={'command':command,'exit':code,'duration_ms':elapsed,'gate_skip':any('skip: ' in s for s in text.splitlines()),'timed_out':code==124}
(root/(label+'-timing.json')).write_text(json.dumps(result,sort_keys=True)+'\n')
print(text,end='')
sys.exit(code)
