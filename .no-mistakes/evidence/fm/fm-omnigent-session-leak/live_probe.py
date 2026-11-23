from __future__ import annotations
import json, os, pathlib, socket, subprocess, time, urllib.request
root=pathlib.Path.cwd(); scratch=root/'.tmp-live-omnigent'; evidence=pathlib.Path('/Users/davidtandoh/.no-mistakes/evidence/01M8559S3M2GMHAM5JYGXT5GX6')
env={k:v for k,v in os.environ.items() if not k.startswith(('OMNIGENT','OTEL_'))}
for name in ('home','config','data'): (scratch/name).mkdir(exist_ok=True)
env.update(HOME=str(scratch/'home'),OMNIGENT_CONFIG_HOME=str(scratch/'config'),OMNIGENT_DATA_DIR=str(scratch/'data'),OMNIGENT_TELEMETRY_ENABLED='false')
with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
url='http://127.0.0.1:'+str(port)
log=(evidence/'scratch-server.log').open('w')
process=subprocess.Popen(['omnigent','server','--host','127.0.0.1','--port',str(port),'--database-uri','sqlite:///'+str(scratch/'chat.db'),'--artifact-location',str(scratch/'artifacts'),'--no-open'],env=env,stdout=log,stderr=subprocess.STDOUT)
try:
 for i in range(300):
  try:
   with urllib.request.urlopen(url+'/openapi.json',timeout=2) as response: api=json.load(response)
   break
  except Exception:
   if process.poll() is not None: raise RuntimeError('scratch server exited')
   time.sleep(.2)
 else: raise RuntimeError('server startup timed out')
 (evidence/'session-api.json').write_text(json.dumps({k:v for k,v in api['paths'].items() if k.startswith('/v1/sessions')},indent=2)+'\n')
 (evidence/'session-schemas.json').write_text(json.dumps({k:v for k,v in api['components']['schemas'].items() if 'Session' in k},indent=2)+'\n')
 def request(path, body=None):
  data=None if body is None else json.dumps(body).encode()
  with urllib.request.urlopen(urllib.request.Request(url+path,data=data,headers={'Content-Type':'application/json'}),timeout=10) as response: return json.load(response)
 agents=request('/v1/agents?limit=1000')
 agent=next(a['id'] for a in agents['data'] if a['name']=='claude-native-ui')
 import http.server, threading, urllib.error, uuid
 events=[]; mode={'value':'slow','get':0,'patch':0}
 class Proxy(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def do_GET(self): self.forward()
  def do_PATCH(self): self.forward()
  def forward(self):
   key='get' if self.command=='GET' else 'patch'; mode[key]+=1
   events.append({'method':self.command,'path':self.path,'fault':mode['value'],'at':time.time()})
   if mode['value']=='down' or (mode['value']=='retry' and mode[key]==1):
    self.send_error(503); return
   if mode['value']=='slow' and self.command=='GET' and mode[key]==1: time.sleep(6)
   body=self.rfile.read(int(self.headers.get('Content-Length','0'))) or None
   try:
    with urllib.request.urlopen(urllib.request.Request(url+self.path,data=body,method=self.command,headers={'Content-Type':'application/json'}),timeout=10) as r: result=r.read(); status=r.status
   except urllib.error.HTTPError as e: result=e.read(); status=e.code
   self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers()
   try: self.wfile.write(result)
   except BrokenPipeError: pass
 proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
 thread=threading.Thread(target=proxy.serve_forever,daemon=True);thread.start()
 proxy_url='http://127.0.0.1:'+str(proxy.server_port)
 state=scratch/'home'/'state';state.mkdir(exist_ok=True)
 results=[]
 def new_session():
  return request('/v1/sessions',{'agent_id':agent,'labels':{'omnigent.wrapper':'claude-code-native-ui'}})
 def cli(args,meta=None,budget=None,background=False):
  e=env.copy()
  for k in list(e):
   if k.startswith('FM_'): e.pop(k)
  e.update(FM_HOME=str(scratch/'home'))
  if meta: e.update(FM_OMNIGENT_RECORD_META=str(meta),FM_OMNIGENT_RECORD_GEN='live.1')
  if budget: e.update(FM_TEST_SEAM='1',FM_TEST_OMNIGENT_NAMING_BUDGET=str(budget),FM_TEST_OMNIGENT_UNNAMED_POLL='0')
  command=['bash',str(root/'bin/fm-omnigent.sh')]+args
  if background: return subprocess.Popen(command,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  r=subprocess.run(command,env=e,capture_output=True,text=True,timeout=30)
  results.append({'command':args,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr});return r
 for fault in ('slow','retry'):
  mode.update(value=fault,get=0,patch=0)
  session=new_session(); sid=session['id']; before=time.monotonic()
  r=cli(['_title-session',proxy_url,sid,'claude','live '+fault,str(session['created_at'])])
  saved=request('/v1/sessions/'+sid)
  assert r.returncode==0 and saved['title']=='live '+fault
  results.append({'scenario':'naming '+fault,'elapsed':time.monotonic()-before,'session':saved})
 mode.update(value='down',get=0,patch=0)
 session=new_session(); sid=session['id'];meta=state/'early.meta';meta.write_text('spawn_gen=live.1\nomnigent=on\n')
 naming=cli(['_title-session',proxy_url,sid,'claude','early cleanup',str(session['created_at'])],meta,6,True)
 pending=state/'.early.omnigent.live.1.meta'
 for i in range(100):
  if pending.exists(): break
  time.sleep(.01)
 assert pending.exists()
 r=cli(['capture',str(meta)]);assert r.returncode==0
 assert 'omnigent_unnamed=' in meta.read_text() and 'omnigent_session=' not in meta.read_text()
 assert cli(['probe',str(meta)]).stdout.strip()=='unknown'
 out,err=naming.communicate(timeout=15);assert naming.returncode==1
 assert 'omnigent-unnamed' in meta.with_suffix('.status').read_text()
 results.append({'scenario':'early capture and visible failure','meta':meta.read_text(),'status':meta.with_suffix('.status').read_text(),'naming_stderr':err})
 mode.update(value='normal',get=0,patch=0)
 r=cli(['archive',str(meta)],budget=6);assert r.returncode==1
 assert request('/v1/sessions/'+sid)['archived']==False
 results.append({'scenario':'online runner fallback refused','session':request('/v1/sessions/'+sid)})
 # API-created sessions have no native runner; the server reports them online.
 # Do not fake an offline runner or bypass Firstmate's fallback safety check.
 bound=state/'bound.meta';bound.write_text('omnigent_session='+sid+'\nomnigent_server='+url+'\n')
 r=cli(['archive',str(bound)]);assert r.returncode==0
 results.append({'scenario':'recorded session archive PATCH','session':request('/v1/sessions/'+sid)})
 # Refuted wrapper must remove the early fallback rather than archive it.
 session=new_session();sid=session['id'];meta=state/'refuted.meta';meta.write_text('spawn_gen=live.1\nomnigent=on\n')
 r=cli(['_title-session',proxy_url,sid,'codex','wrong wrapper',str(session['created_at'])],meta,6)
 assert r.returncode==1 and 'omnigent_unnamed=' not in meta.read_text()
 assert not (state/'.refuted.omnigent.live.1.meta').exists()
 assert request('/v1/sessions/'+sid)['archived']==False
 results.append({'scenario':'refuted identity removed','meta':meta.read_text()})
 proxy.shutdown();proxy.server_close()
 (evidence/'live-results.json').write_text(json.dumps({'results':results,'http_requests':events},indent=2)+'\n')
 print('PASS: real-server delayed GET, GET/PATCH retries, early capture, unknown probe, visible status, online refusal, recorded-session archive, and refuted identity removal. Offline fallback requires a real stopped runner and was not exercised live.')

finally:
 if 'results' in locals(): (evidence/'live-results.json').write_text(json.dumps({'results':results,'http_requests':events},indent=2)+'\n')
 process.terminate()
 try: process.wait(timeout=15)
 except subprocess.TimeoutExpired: process.kill(); process.wait()
 log.close()
