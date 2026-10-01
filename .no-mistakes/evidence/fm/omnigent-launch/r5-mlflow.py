from __future__ import annotations
import json, time, subprocess
from pathlib import Path
from mlflow import MlflowClient
E=Path('/Users/davidtandoh/.no-mistakes/evidence/01M3VQQ8KSX5QDVVFHY221R9G7')
session=json.loads((E/'r5-primary-worker-result.json').read_text())['worker_session']
assert session
client=MlflowClient(tracking_uri='http://127.0.0.1:5051')
found=[]
for attempt in range(12):
    status=json.loads(subprocess.check_output(['agent-kit','observe','serve','status','--json']))
    if status.get('status')!='running':
        (E/'r5-service-degraded.json').write_text(json.dumps(status,sort_keys=True)+'\n')
        with Path(status['redactor_log']).open('rb') as f:
            f.seek(0,2); f.seek(max(0,f.tell()-32768)); tail=f.read(32768)
        (E/'r5-redactor-tail.log').write_bytes(tail)
        raise RuntimeError('Shared observation degraded; stopped without repair')
    token=None
    for page in range(10):
        traces=client.search_traces(locations=['1'],filter_string="metadata.`mlflow.trace.session` = '"+session+"'",max_results=100,page_token=token)
        for trace in traces:
            spans=[s for s in trace.data.spans if s.name.startswith('agent:') and s.attributes.get('session.id')==session]
            if spans:
                found.append({'trace_id':trace.info.trace_id,'status':str(trace.info.status),'session':session,'response':trace.data.response,'agent_spans':[{'name':s.name,'output.value':s.attributes.get('output.value')} for s in spans]})
        token=traces.token
        if not token: break
    if any('OMNI_R5_WORKER_FINAL' in str(t['response']) and any('OMNI_R5_WORKER_FINAL' in str(s['output.value']) for s in t['agent_spans']) for t in found): break
    time.sleep(5)
(E/'r5-mlflow.json').write_text(json.dumps(found,sort_keys=True,indent=2)+'\n')
assert any('OMNI_R5_WORKER_FINAL' in str(t['response']) and any('OMNI_R5_WORKER_FINAL' in str(s['output.value']) for s in t['agent_spans']) for t in found), 'No session-matched final-response trace found'
print('MLflow recorded the worker final response in both trace.data.response and agent output.value')
