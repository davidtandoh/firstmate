#!/usr/bin/env bash
# Generation-bound native Codex notification, reconciliation and retry behavior.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-notify)
for home_mode in default explicit; do
  case_root="$TMP_ROOT/launch-$home_mode"
  home="$case_root/home"
  fakebin=$(fm_test_make_spawn_fakebin "$case_root/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" direct-home
  fm_git_worktree "$case_root/project" "$case_root/wt" "wt-$home_mode"
  (
    unset CODEX_HOME
    expected="$home/user-home/.codex"
    if [ "$home_mode" = explicit ]; then
      expected="$case_root/custom codex home"
      export CODEX_HOME="$expected"
    fi
    FM_FAKE_LAUNCH_LOG="$case_root/launch.log" \
      fm_test_run_spawn "$home" "$case_root/wt" "$fakebin" direct-home "$case_root/project" --scout \
      > "$case_root/spawn.out" || fail "direct $home_mode spawn: $(cat "$case_root/spawn.out")"
    cat > "$fakebin/codex" <<'SH'
#!/bin/sh
printf '%s\n' "$CODEX_HOME"
SH
    chmod +x "$fakebin/codex"
    seen=$(env -i HOME="$case_root/pane-home" CODEX_HOME="$case_root/wrong-home" \
      PATH="$fakebin:$PATH" /bin/bash -c "$(cat "$case_root/launch.log")")
    assert_equals "$expected" "$seen" "direct $home_mode launch must pin its native home"
  )
done
pass 'direct launches pin the default or explicit native home across pane environments'
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
from __future__ import annotations
import json, os, pathlib, subprocess, sys
root, lab = map(pathlib.Path, sys.argv[1:])
state, wt, bridge = lab/'state', lab/'wt', lab/'bridge'
for path in (state, wt, bridge/'codex-home'/'sessions'/'2026'/'10'/'26'):
    path.mkdir(parents=True, exist_ok=True)
thread = '01a177db-8065-7730-9bd7-fd12228c3809'
turn = '01a177db-81ef-7a21-bd77-199313862f5c'
gen = 's1793012236.123.456'
brief = lab/'brief.md'
brief.write_text('Do the assigned work.')
meta = state/'task.meta'
def metadata(generation=gen, harness='codex'):
    meta.write_text('worktree={}\nharness={}\nkind=scout\nspawn_gen={}\nomnigent=on\nmodel=gpt-6.1-sol\n'.format(wt,harness,generation))
metadata()
native = {'thread_id':thread, 'codex_home':str(bridge/'codex-home'), 'cwd':str(wt), 'active_turn_id':turn, 'session_id':'owned-session'}
def native_state():
    (bridge/'state.json').write_text(json.dumps(native))
native_state()
rollout = bridge/'codex-home'/'sessions'/'2026'/'10'/'26'/('rollout-2026-10-26T10-57-16-'+thread+'.jsonl')
def events(*payloads):
    header = {'type':'session_meta','payload':{'id':thread,'cwd':str(wt)}}
    rollout.write_text('\n'.join(json.dumps(x) for x in [header]+[{'type':'event_msg','payload':p} for p in payloads])+'\n')
events({'type':'task_started','turn_id':turn})
env = dict(os.environ, HOME=str(lab), CODEX_HOME=str(bridge/'codex-home'))
env.pop('HARNESS_CODEX_NATIVE_BRIDGE_DIR',None)
command = ['bash',str(root/'bin/fm-codex-native.sh')]
def run(op, *args, ok=True, extra=None):
    result = subprocess.run(command+[op,str(state),'task']+list(args),env=dict(env,**(extra or {})),text=True,capture_output=True)
    assert (result.returncode == 0) == ok, (op,result.returncode,result.stdout,result.stderr)
    return result.stdout
payload = {'type':'agent-turn-complete','thread-id':thread,'turn-id':turn,'cwd':str(wt),'input-messages':['Do the assigned work.']}
def notify(data=payload, generation=gen, **kwargs):
    return run('notify',generation,str(brief),json.dumps(data),**kwargs)
marker = state/'task.turn-ended'
# Auxiliary event binds the exact bridge, but cannot emit completion.
notify(dict(payload,**{'thread-id':'auxiliary'}))
assert not marker.exists()
assert (state/'task.codex-native.json').exists()
notify()  # Early canonical callback is not completion evidence either.
assert not marker.exists()
events({'type':'task_started','turn_id':turn},{'type':'task_complete','turn_id':turn,'last_agent_message':'done'})
native['active_turn_id']=None
native_state()
notify()
assert marker.exists()
stamp=marker.stat().st_mtime_ns
notify()
assert marker.stat().st_mtime_ns == stamp
print('ok - auxiliary and early events cannot mark completion; canonical completion signals once')
marker.unlink()
metadata('s1793012237.123.456')
notify(ok=False)
assert not marker.exists()
assert json.loads(run('read'))['state'] == 'unknown'
metadata()
native['cwd']=str(lab/'foreign')
native_state()
notify(ok=False)
native['cwd']=str(wt)
native_state()
notify(extra={'HARNESS_CODEX_NATIVE_BRIDGE_DIR':str(lab/'missing')},ok=False)
assert not marker.exists()
print('ok - stale generation, wrong worktree and explicit bad bridge fail closed')
# Canonical failure wins over a prior paused declaration through the public reader.
error={'message':'Selected model is at capacity.','codex_error_info':'server_overloaded'}
events({'type':'task_started','turn_id':turn},{'type':'task_complete','turn_id':turn,'error':error,'last_agent_message':None})
(state/'task.status').write_text('paused [at=1793012236]: waiting on validation\n')
current=json.loads(run('read'))
assert current['state']=='failed' and current['code']=='server_overloaded',current
crew=subprocess.check_output(['bash',str(root/'bin/fm-crew-state.sh'),'task'],env=dict(env,FM_STATE_OVERRIDE=str(state)),text=True)
assert crew.rstrip('\n').split(' · ')[:3] == ['state: failed', 'source: codex-native', 'canonical turn '+turn+' failed: server_overloaded: Selected model is at capacity.'],crew
snapshot=lab/'snapshot.meta'
snapshot.write_bytes(meta.read_bytes())
snapshot_crew=subprocess.check_output(['bash',str(root/'bin/fm-crew-state.sh'),'task'],env=dict(env,FM_STATE_OVERRIDE=str(state),FM_CREW_STATE_META_OVERRIDE=str(snapshot)),text=True)
assert snapshot_crew == crew,(snapshot_crew,crew)
# New turn and successful completion cannot retain the old failure.
native['active_turn_id']='next-turn'
native_state()
assert json.loads(run('read'))['state']=='unknown'
events({'type':'task_started','turn_id':turn},{'type':'task_complete','turn_id':turn,'error':error},{'type':'task_started','turn_id':'next-turn'})
native['active_turn_id']=None
native_state()
assert json.loads(run('read'))['state']=='unknown'
print('ok - canonical overload overrides paused status; a later turn clears the failure')
events({'type':'task_started','turn_id':turn},{'type':'task_complete','turn_id':turn,'error':error})
# Copy the toolbelt links to exercise the public retry operation with a recording sender.
toolbelt=lab/'toolbelt'
toolbelt.mkdir()
for source in (root/'bin').iterdir():
    (toolbelt/source.name).symlink_to(source)
(toolbelt/'fm-codex-native.sh').unlink()
(toolbelt/'fm-codex-native.sh').write_bytes((root/'bin/fm-codex-native.sh').read_bytes())
(toolbelt/'fm-send.sh').unlink()
(toolbelt/'fm-send.sh').write_text('#!/bin/sh\nprintf "%s\\n" "$FM_SEND_EXPECTED_SPAWN_GEN" "$@" >> "$HOME/sends"\n')
(toolbelt/'fm-send.sh').chmod(0o755)
command=['bash',str(toolbelt/'fm-codex-native.sh')]
attempts=[subprocess.Popen(command+['retry',str(state),'task'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
for attempt in attempts:
    attempt.communicate()
assert sorted(attempt.returncode for attempt in attempts)==[0,1]
run('retry',ok=False)
assert (lab/'sends').read_text().splitlines()[0]==gen
assert (lab/'sends').read_text().count('task\n')==1
# Another failure in this task generation gets no second retry.
events({'type':'task_complete','turn_id':'second-failure','error':error})
run('retry',ok=False)
print('ok - overload recovery sends one generation-bound resume, with no model switch or duplicate gate response')
# Unrelated errors never consume a retry or send a prompt.
(state/'task.codex-retry.json').unlink()
events({'type':'task_complete','turn_id':turn,'error':{'message':'bad auth','codex_error_info':'unauthorized'}})
run('retry',ok=False)
assert not (state/'task.codex-retry.json').exists()
# Oversized and symlinked sources remain unknown and cannot emit a marker.
(bridge/'state.json').write_text(' ' * 524289)
assert json.loads(run('read'))['state']=='unknown'
notify(ok=False)
native_state()
metadata(harness='claude')
notify(ok=False)
metadata()
rollout.unlink()
rollout.symlink_to(brief)
assert json.loads(run('read'))['state']=='unknown'
notify(ok=False)
assert not marker.exists()
print('ok - nontransient errors and unsafe sources cannot trigger recovery or completion')
command = ['bash',str(root/'bin/fm-codex-native.sh')]
state = lab/'direct-state'
state.mkdir()
meta = state/'task.meta'
meta.write_text('worktree={}\nharness=codex\nkind=scout\nspawn_gen={}\nomnigent=off\n'.format(wt,gen))
marker = state/'task.turn-ended'
direct_payload = dict(payload, **{'input-messages':['\u2063FIRSTMATE_OP: v1 launch-brief: '+brief.read_text()]})
for home_mode in ('unset', 'empty', 'explicit'):
    env.pop('CODEX_HOME',None)
    home = lab/'.codex'
    if home_mode == 'empty':
        env['CODEX_HOME']=''
    elif home_mode == 'explicit':
        home = lab/'explicit codex home'
        env['CODEX_HOME']=str(home)
    rollout = home/'sessions'/'2026'/'10'/'26'/('rollout-2026-10-26T10-57-16-'+thread+'.jsonl')
    rollout.parent.mkdir(parents=True,exist_ok=True)
    events({'type':'task_complete','turn_id':turn,'error':error})
    assert json.loads(notify(direct_payload))['accepted'] is True
    binding=json.loads((state/'task.codex-native.json').read_text())
    assert binding['codex_home']==str(home),binding
    assert json.loads(marker.read_text())=={'generation':gen,'thread_id':thread,'turn_id':turn}
    assert json.loads(run('read'))['code']=='server_overloaded'
    marker.unlink()
    (state/'task.codex-native.json').unlink()
    assert json.loads(run('read'))['state']=='unknown'
env['CODEX_HOME']='relative-home'
notify(direct_payload,ok=False)
assert not marker.exists() and not (state/'task.codex-native.json').exists()
env.pop('CODEX_HOME')
notify(payload,ok=False)
notify(dict(direct_payload,**{'cwd':str(lab/'foreign')}),ok=False)
notify(direct_payload,generation='stale-generation',ok=False)
assert not marker.exists() and not (state/'task.codex-native.json').exists()
print('ok - direct default, empty and explicit homes preserve completion and failure evidence; unbound events fail closed')
PY
