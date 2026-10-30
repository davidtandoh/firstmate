from __future__ import annotations
import json, os, pathlib, signal, subprocess, sys, time
root=pathlib.Path(__file__).parent
label, seconds, *command=sys.argv[1:]
start=time.monotonic()
with (root/(label+'.log')).open('wb') as output:
    process=subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code=process.wait(timeout=int(seconds))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        code=124
text=(root/(label+'.log')).read_text(errors='replace')
result={'command':command,'duration_ms':round((time.monotonic()-start)*1000),'exit':code,'gate_skip':any(line.startswith('skip:') for line in text.splitlines()),'timed_out':code==124}
(root/(label+'-timing.json')).write_text(json.dumps(result,sort_keys=True)+'\n')
print(json.dumps(result,sort_keys=True))
sys.exit(code)
