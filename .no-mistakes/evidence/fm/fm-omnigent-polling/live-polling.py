import concurrent.futures, http.server, json, os, pathlib, shutil, subprocess, tempfile, threading, time, urllib.request
ROOT=pathlib.Path.cwd()
UPSTREAM='http://127.0.0.1:52131'
rows=json.load(urllib.request.urlopen(UPSTREAM+'/v1/sessions',timeout=10))['data']
session=next(r['id'] for r in rows if not r.get('archived'))
requests=[]
class Proxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            response=urllib.request.urlopen(UPSTREAM+self.path,timeout=8)
        except urllib.error.HTTPError as error:
            response=error
        body=response.read(2097153)
        requests.append({'path':self.path,'status':response.status})
        self.send_response(response.status); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
threading.Thread(target=proxy.serve_forever,daemon=True).start()
base=ROOT/'.tmp'
base.mkdir(exist_ok=True)
lab=pathlib.Path(tempfile.mkdtemp(prefix='polling-live-',dir=base))
meta=lab/'bound.meta'
meta.write_text('spawn_gen=live.1\nomnigent=on\nomnigent_session='+session+'\nomnigent_server=http://127.0.0.1:'+str(proxy.server_port)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','OMNIGENT','OTEL_'))}
env['FM_HOME']=str(lab)
def call(field,fresh=False):
    result=subprocess.run(['bash','bin/fm-omnigent.sh',field]+(['--fresh'] if fresh else [])+[str(meta)],env=env,text=True,capture_output=True,timeout=15)
    assert result.returncode==0, result.stderr
    value=result.stdout.strip()
    if field=='approvals':
        assert value!='unknown', 'real session approval projection unknown'
        value={'pending_count':len(json.loads(value))}
    return value
try:
    values=[]
    for _ in range(4):
        values.append({'probe':call('probe'),'approvals':call('approvals')})
    assert all(r['probe']=='alive' for r in values),values
    assert len(requests)==1,requests
    print(json.dumps({'scenario':'four approval/liveness pairs share one real session GET','results':values,'upstream_requests':requests}),flush=True)
    value=call('probe',True)
    assert value=='alive' and len(requests)==2
    assert call('probe')=='alive' and len(requests)==2
    print(json.dumps({'scenario':'fresh read bypasses cache and preserves shared snapshot','probe':value,'total_upstream_GETs':len(requests)}),flush=True)
    time.sleep(31)
    assert call('probe')=='alive' and len(requests)==3
    print(json.dumps({'scenario':'expired snapshot refreshes against real server','total_upstream_GETs':len(requests)}),flush=True)
    meta.write_text(meta.read_text().replace(session,'0'*32).replace('live.1','live.2'))
    assert call('probe')=='dead' and len(requests)==4
    print(json.dumps({'scenario':'new launch binding invalidates snapshot; real missing session is dead','last_request':requests[-1]}),flush=True)
finally:
    proxy.shutdown(); proxy.server_close(); shutil.rmtree(lab)
    try: base.rmdir()
    except OSError: pass
