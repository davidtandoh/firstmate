#!/usr/bin/env bash
# Behavior tests for bin/fm-upgrade-window-lib.sh, Firstmate's reader of the
# Agent Kit's Omnigent upgrade pause window: an active window defers and is
# held without acknowledgement, an expired or absent window defers nothing, an
# unreadable one warns and defers nothing, and a closed job raises one wake for
# a home that deferred work or owns an interrupted session, naming those tasks.
# shellcheck disable=SC2030,SC2031 # Subshell tests intentionally isolate environment changes; later tests use the parent values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-upgrade-window-lib)
export AGENT_KIT_OBSERVATION_DIR="$TMP_ROOT/observation"
SERVE="$AGENT_KIT_OBSERVATION_DIR/serve"
WINDOW="$SERVE/upgrade-window.json"
ACK="$SERVE/upgrade-window.ack.json"
mkdir -p "$SERVE"

# shellcheck source=bin/fm-upgrade-window-lib.sh
. "$ROOT/bin/fm-upgrade-window-lib.sh"

# write_window <job> <phase> <expires-offset-seconds> [outcome] [sessions-json]
write_window() {
  jq -n --arg job "$1" --arg phase "$2" --argjson exp "$(( $(date +%s) + $3 ))" \
    --arg outcome "${4:-}" --argjson sessions "${5:-[]}" \
    '{schema_version:"1", job:$job, phase:$phase,
      outcome:(if $outcome == "" then null else $outcome end),
      requested_at:($exp - 600), expires_at:$exp, drain:null,
      firstmate_ack:null, interrupted_sessions:$sessions}' > "$WINDOW"
}

new_state() { # <name> -> state dir
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

test_absent_window_defers_nothing() {
  rm -f "$WINDOW"
  fm_upgrade_window_gate "task t1" 2>"$TMP_ROOT/err" || fail 'absent window deferred'
  [ ! -s "$TMP_ROOT/err" ] || fail "absent window printed: $(cat "$TMP_ROOT/err")"
  pass 'an absent window defers nothing'
}

test_paused_window_defers_and_records() {
  local state rc=0
  state=$(new_state paused)
  for phase in pausing switching; do
    write_window job-p "$phase" 600
    rc=0
    fm_upgrade_window_gate "task t1" "$state" 2>"$TMP_ROOT/err" || rc=$?
    [ "$rc" = 75 ] || fail "$phase window returned $rc, not 75"
    grep -q '^deferred: .*job job-p.*task t1 was not started' "$TMP_ROOT/err" || fail "$phase deferral unclear: $(cat "$TMP_ROOT/err")"
  done
  [ "$(cat "$state/.upgrade-window-deferred")" = job-p ] || fail 'deferral was not recorded for the job'
  pass 'a pausing or switching window before expiry defers with 75 and records the job'
}

test_expired_window_defers_nothing() {
  write_window job-e switching -1
  fm_upgrade_window_gate "task t1" 2>/dev/null || fail 'expired window deferred'
  [ "$FM_UPGRADE_WINDOW_STATE" = closed ] && [ "$FM_UPGRADE_WINDOW_OUTCOME" = expired ] || fail 'expired window not read as closed'
  pass 'an expired window defers nothing'
}

test_invalid_window_warns_and_defers_nothing() {
  printf '{"schema_version":"2","job":"x","phase":"pausing","expires_at":9999999999}\n' > "$WINDOW"
  fm_upgrade_window_gate "task t1" 2>"$TMP_ROOT/err" || fail 'invalid window deferred'
  grep -q '^warning: ignoring unreadable Omnigent upgrade window' "$TMP_ROOT/err" || fail 'invalid window did not warn'
  printf 'not json' > "$WINDOW"
  fm_upgrade_window_gate "task t1" 2>/dev/null || fail 'malformed window deferred'
  pass 'an unreadable window warns and defers nothing'
}

test_active_window_leaves_acknowledgement_to_kit() {
  local state
  state=$(new_state ack)
  rm -f "$ACK"
  write_window job-a pausing 600
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'an active window woke the supervisor'
  [ ! -e "$ACK" ] || fail 'watcher acknowledged without proving all in-flight launches stopped'
  pass 'active window waits for the bounded Kit drain without acknowledging'
}

test_resumed_window_names_interrupted_workers_once() {
  local state
  state=$(new_state resumed)
  printf 'omnigent=on\nomnigent_session=sess-1\n' > "$state/w1.meta"
  printf 'omnigent=on\nomnigent_session=sess-other\n' > "$state/w2.meta"
  printf 'harness=codex\n' > "$state/w3.meta"
  write_window job-r resumed 600 upgraded '["sess-1","sess-foreign"]'
  fm_upgrade_window_supervise "$state"
  case "$FM_UPGRADE_WINDOW_REASON" in
    'check: omnigent-upgrade job-r closed (upgraded);'*'relaunch interrupted or stopped workers with bin/fm-control.sh <task> relaunch: w1') ;;
    *) fail "resumed reason wrong: $FM_UPGRADE_WINDOW_REASON" ;;
  esac
  fm_upgrade_window_commit "$state"
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'a surfaced job woke again'
  pass 'a resumed window wakes once, naming only this home tasks it interrupted'
}

test_close_wakes_only_a_home_that_deferred() {
  local quiet busy
  quiet=$(new_state quiet)
  busy=$(new_state busy)
  write_window job-d switching 600
  fm_upgrade_window_gate "task t1" "$busy" 2>/dev/null && fail 'active window admitted work'
  write_window job-d switching -1
  fm_upgrade_window_supervise "$quiet"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'a home that deferred nothing was woken'
  fm_upgrade_window_supervise "$busy"
  [ "$FM_UPGRADE_WINDOW_REASON" = 'check: omnigent-upgrade job-d closed (expired); Omnigent dispatch and steering resume' ] \
    || fail "expiry reason wrong: $FM_UPGRADE_WINDOW_REASON"
  fm_upgrade_window_commit "$busy"
  [ ! -e "$busy/.upgrade-window-deferred" ] || fail 'deferral marker survived the commit'
  write_window job-v pausing 600
  fm_upgrade_window_gate "task t1" "$busy" 2>/dev/null && fail 'active window admitted work'
  rm -f "$WINDOW"
  fm_upgrade_window_supervise "$busy"
  case "$FM_UPGRADE_WINDOW_REASON" in 'check: omnigent-upgrade job-v closed (window absent);'*) ;; *) fail "vanished window reason wrong: $FM_UPGRADE_WINDOW_REASON" ;; esac
  pass 'expiry or a vanished window wakes only a home that deferred work for that job'
}

test_shared_ring_preserves_pending_record() (
  local state rec rc=0
  state=$(new_state ring)
  export FM_STATE_OVERRIDE="$state"
  . "$ROOT/bin/fm-task-inbox-lib.sh"
  printf 'omnigent=on\n' > "$state/w1.meta"
  rec=$(fm_task_inbox_write "$state" w1 'durable feedback') || fail 'enqueue failed'
  write_window job-ring switching 600
  fm_task_inbox_ring tmux nonexistent "$rec" fm-w1 2>"$TMP_ROOT/ring.err" || rc=$?
  [ "$rc" = 75 ] || fail "shared ring did not hold delivery: $rc"
  [ -f "$rec" ] || fail 'held feedback lost its durable record'
  [ "$(cat "$state/.upgrade-window-deferred")" = job-ring ] || fail 'shared ring did not remember deferral'
  pass 'shared ring holds durable feedback before touching the endpoint'
)

test_secondmate_pause_preserves_recovery_budget() (
  local rc=0
  STATE=$(new_state recovery)
  export FM_STATE_OVERRIDE="$STATE"
  . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
  printf 'omnigent=on\nkind=secondmate\nwindow=gone\n' > "$STATE/mate.meta"
  write_window job-recovery pausing 600
  FM_SM_LIVE_STATE=dead FM_SM_LIVE_KILL=1 FM_SM_LIVE_RESUME=0
  fm_secondmate_liveness_relaunch "$STATE/mate.meta" mate 1 2>"$TMP_ROOT/recovery.err" || rc=$?
  [ "$rc" = 75 ] || fail "recovery did not defer: $rc"
  [ ! -e "$STATE/.secondmate-relaunch-mate" ] || fail 'pause consumed recovery budget'
  [ ! -e "$STATE/.secondmate-relaunch.lock" ] || fail 'pause mutated endpoint recovery locks'
  pass 'secondmate pause consumes no recovery attempt or endpoint mutation'
)

test_remote_window_uses_server_owner() (
  local state rc=0 copy now
  state=$(new_state remote)
  export FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" FM_OMNIGENT_SERVER=https://owner.example:8443
  now=$(date +%s)
  copy="$state/upgrade-window-owner.example:8443.json"
  write_window job-remote resumed 600 upgraded
  jq -n --arg server "$FM_OMNIGENT_SERVER" --argjson now "$now" --slurpfile window "$WINDOW" \
    '{schema_version:1,server:$server,published_at:$now,window:$window[0]}' > "$copy"
  fm_upgrade_window_gate 'remote doorbell' "$state" "$FM_OMNIGENT_SERVER" || fail 'fresh closed copy held doorbell'
  jq '.window.phase="pausing"' "$copy" > "$copy.tmp" && mv "$copy.tmp" "$copy"
  fm_upgrade_window_gate 'remote doorbell' "$state" "$FM_OMNIGENT_SERVER" 2>/dev/null && fail 'active copy admitted doorbell'
  [ "$FM_UPGRADE_WINDOW_STATE" = active ] || fail 'active copy was not read'
  for invalid in stale future malformed missing; do
    case "$invalid" in
      stale) jq '.published_at -= 601' "$copy" > "$copy.tmp"; mv "$copy.tmp" "$copy" ;;
      future) jq --argjson now "$now" '.published_at=$now+1' "$copy" > "$copy.tmp"; mv "$copy.tmp" "$copy" ;;
      malformed) printf '{broken' > "$copy" ;;
      missing) rm "$copy" ;;
    esac
    rc=0
    fm_upgrade_window_gate 'remote doorbell' "$state" "$FM_OMNIGENT_SERVER" 2>/dev/null || rc=$?
    [ "$rc" = 75 ] && [ "$FM_UPGRADE_WINDOW_STATE" = unavailable ] || fail "$invalid copy admitted doorbell"
  done
  jq -cn --arg server "$FM_OMNIGENT_SERVER" --argjson now "$now" \
    '{schema_version:1,server:$server,published_at:$now,window:null}' > "$copy"
  fm_upgrade_window_gate 'remote doorbell' "$state" "$FM_OMNIGENT_SERVER" || fail 'fresh absent copy held doorbell'
  pass 'remote copies admit closed windows and defer active, stale, future, malformed or missing copies'
)

test_close_names_unlisted_stopped_runner() (
  local state
  state=$(new_state stopped)
  . "$ROOT/tests/omnigent-fixture.sh"
  fm_test_omnigent_service "$TMP_ROOT/probe-service" "$TMP_ROOT/probe-tools"
  export PATH="$TMP_ROOT/probe-tools:$PATH" OMNI_SESSION_STATE=missing
  printf 'omnigent=on\nomnigent_session=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nomnigent_server=http://127.0.0.1:6767\n' > "$state/stopped.meta"
  printf 'omnigent=on\n' > "$state/unbound.meta"
  printf 'omnigent=on\nremote_host=worker\n' > "$state/remote.meta"
  printf 'omnigent=on\nremote_host=worker\nomnigent_session=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$state/remote-bound.meta"
  write_window job-stopped resumed 600 upgraded
  fm_upgrade_window_supervise "$state"
  case "$FM_UPGRADE_WINDOW_REASON" in *'relaunch: stopped') ;; *) fail "unlisted stopped runner omitted: $FM_UPGRADE_WINDOW_REASON" ;; esac
  fm_upgrade_window_commit "$state"
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'stopped runner wake repeated'
  rm "$state/.stopped.omnigent-snapshot.json"
  write_window job-disconnected resumed 600 upgraded
  export OMNI_SESSION_STATE=runner-gone
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'disconnected runner named for recovery'
  rm "$state/.stopped.omnigent-snapshot.json"
  write_window job-live resumed 600 upgraded
  export OMNI_SESSION_STATE=alive
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'live runner named for recovery'
  pass 'close reconciles unlisted stopped sessions and preserves live workers'
)

test_launch_rechecks_after_preflight() (
  local rc=0
  . "$ROOT/tests/omnigent-fixture.sh"
  fm_test_omnigent_service "$TMP_ROOT/race-service" "$TMP_ROOT/race-tools"
  export PATH="$TMP_ROOT/race-tools:$PATH" FM_HOME="$TMP_ROOT/race-home"
  mkdir -p "$FM_HOME/state"
  export FM_STATE_OVERRIDE="$FM_HOME/state"
  write_window job-race pausing 600
  export RACE_WINDOW="$TMP_ROOT/race-window.json" RACE_DEST="$WINDOW"
  mv "$WINDOW" "$RACE_WINDOW"
  mv "$TMP_ROOT/race-tools/agent-kit" "$TMP_ROOT/race-tools/agent-kit-original"
  cat > "$TMP_ROOT/race-tools/agent-kit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'observe serve status --readiness --json' ]; then cp "$RACE_WINDOW" "$RACE_DEST"; fi
exec "${0%/*}/agent-kit-original" "$@"
SH
  chmod +x "$TMP_ROOT/race-tools/agent-kit"
  bash "$ROOT/bin/fm-omnigent.sh" run codex 'initial turn' >"$TMP_ROOT/race.out" 2>"$TMP_ROOT/race.err" || rc=$?
  [ "$rc" = 75 ] || fail "late window did not defer launch: $rc: $(cat "$TMP_ROOT/race.err")"
  [ -f "$WINDOW" ] || fail 'preflight did not publish the racing window'
  [ ! -e "$TMP_ROOT/race-service/result.json" ] || fail 'native launch ran during pause'
  pass 'shared launch rechecks a window published during preflight'
)

test_remote_recovery_checks_destination_before_attempt() (
  local state rc status
  state=$(new_state destination-recovery)
  export FM_STATE_OVERRIDE="$state" FM_HOME="${state%/state}" DESTINATION_CODE_ROOT="$ROOT"
  . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
  FM_SM_LIVE_LIB_DIR="$TMP_ROOT/recovery-transport"
  mkdir -p "$FM_SM_LIVE_LIB_DIR" "$TMP_ROOT/destination/serve"
  ln -s "$ROOT/bin/fm-upgrade-window-lib.sh" "$FM_SM_LIVE_LIB_DIR/fm-upgrade-window-lib.sh"
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$FM_SM_LIVE_LIB_DIR/fm-timeout-lib.sh"
  cat > "$FM_SM_LIVE_LIB_DIR/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = 'mate fm-omnigent.sh upgrade-gate' ] || exit 2
[ "${DESTINATION_UNAVAILABLE:-0}" = 0 ] || exit 255
AGENT_KIT_OBSERVATION_DIR="$DESTINATION_OBSERVATION" exec bash "$DESTINATION_CODE_ROOT/bin/fm-omnigent.sh" upgrade-gate
SH
  chmod +x "$FM_SM_LIVE_LIB_DIR/fm-on.sh"
  printf 'kind=secondmate\nomnigent=on\nremote_host=worker\nwindow=gone\n' > "$state/mate.meta"
  write_window job-destination pausing 600
  cp "$WINDOW" "$TMP_ROOT/destination/serve/upgrade-window.json"
  rm "$WINDOW"
  export DESTINATION_OBSERVATION="$TMP_ROOT/destination"
  STATE=$state FM_SM_LIVE_STATE=dead FM_SM_LIVE_KILL=1 FM_SM_LIVE_RESUME=0
  for status in paused unavailable; do
    rc=0
    [ "$status" != unavailable ] || export DESTINATION_UNAVAILABLE=1
    fm_secondmate_liveness_relaunch "$state/mate.meta" mate 1 || rc=$?
    if [ "$status" = paused ]; then
      [ "$rc" = 75 ] || fail "paused destination returned $rc instead of deferring"
    else
      [ "$rc" = 255 ] || fail "unavailable destination returned $rc instead of preserving transport failure"
    fi
    [ ! -e "$state/.secondmate-relaunch-mate" ] || fail "$status destination consumed an attempt"
    [ ! -e "$state/.secondmate-relaunch.lock" ] || fail "$status destination changed recovery locks"
  done
  pass 'remote destination pause or unavailable transport consumes no recovery budget'
)

test_close_respects_parking_and_proves_unbound_stop() (
  local state tasks
  state=$(new_state lifecycle)
  mkdir -p "$TMP_ROOT/lifecycle-tools"
  cat > "$TMP_ROOT/lifecycle-tools/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list-windows) printf 'live\n' ;;
  display-message)
    for arg in "$@"; do case "$arg" in *pane_current_command*) printf 'claude\n'; exit 0 ;; esac; done
    ;;
esac
SH
  chmod +x "$TMP_ROOT/lifecycle-tools/tmux"
  export PATH="$TMP_ROOT/lifecycle-tools:$PATH"
  printf 'omnigent=on\nwindow=sess:late\n' > "$state/late.meta"
  printf 'omnigent=on\nwindow=sess:live\n' > "$state/live.meta"
  printf 'omnigent=on\nwindow=unproven\n' > "$state/unknown.meta"
  printf 'omnigent=on\nremote_host=worker\nwindow=sess:late\n' > "$state/remote.meta"
  printf 'omnigent=on\nomnigent_session=sess-parked\n' > "$state/parked.meta"
  printf 'pr=42\nparked_at=1\n' > "$state/parked.review-park"
  printf 'omnigent=on\nwindow=sess:late\n' > "$state/parking.meta"
  printf 'pr=43\npending=1\n' > "$state/parking.review-park"
  write_window job-lifecycle resumed 600 upgraded '["sess-parked"]'
  fm_upgrade_window_supervise "$state"
  case "$FM_UPGRADE_WINDOW_REASON" in *'relaunch: late') ;; *) fail "lifecycle recovery wrong: $FM_UPGRADE_WINDOW_REASON" ;; esac
  tasks=$(fm_upgrade_window_tasks "$state")
  [ "$tasks" = late ] || fail "recovery included parked, remote or unproven workers: $tasks"
  pass 'close recovers a proven missing local launch while preserving parked and live workers'
)

test_remote_send_preserves_retryable_deferral() (
  local dir home state rc records item
  dir="$TMP_ROOT/remote-send"
  home="$dir/home"
  state="$home/state/parent-route"
  mkdir -p "$dir/code/bin" "$home/bin" "$state" "$dir/user"
  cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$dir/code/bin/"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  : > "$home/AGENTS.md"
  for item in fm-ff-lib.sh fm-pending-reply-lib.sh fm-remote-herdr-identity-lib.sh; do : > "$dir/code/bin/$item"; done
  cat > "$dir/code/bin/fm-backend.sh" <<'SH'
. "$SEND_CODE_ROOT/bin/fm-backend.sh"
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=rex
  FM_BACKEND_VALIDATED_TARGET=session:block
}
fm_backend_agent_state() { printf alive; }
fm_backend_composer_state() { printf empty; }
fm_backend_send_text_submit() { printf '%s\n' "$3" >> "$SEND_RING_LOG"; printf submitted; }
SH
  cat > "$dir/code/bin/fm-task-inbox-lib.sh" <<'SH'
. "$SEND_CODE_ROOT/bin/fm-task-inbox-lib.sh"
. "${BASH_SOURCE[0]%/*}/fm-backend.sh"
SH
  printf 'omnigent=on\nrex_server=unix:///fixture\n' > "$state/mate.meta"
  write_window job-send switching 600
  for item in first retry; do
    rc=0
    env -i PATH="$PATH" HOME="$dir/user" FM_HOME="$home" \
      SEND_CODE_ROOT="$ROOT" SEND_RING_LOG="$dir/rings" AGENT_KIT_OBSERVATION_DIR="$AGENT_KIT_OBSERVATION_DIR" \
      bash "$dir/code/bin/fm-remote-secondmate-control.sh" send mate 'same durable request' fire-and-forget \
      > "$dir/out" 2> "$dir/err" || rc=$?
    [ "$rc" = 75 ] || fail "remote $item did not defer: $rc: $(cat "$dir/err")"
    [ -f "$state/mate.inbox/001.msg" ] || fail 'remote deferred record was lost'
    [ ! -e "$dir/rings" ] || fail 'remote pause rang the endpoint'
  done
  records=$(find "$state/mate.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail 'retry duplicated the deferred remote record'
  write_window job-send resumed 600 upgraded
  env -i PATH="$PATH" HOME="$dir/user" FM_HOME="$home" \
    SEND_CODE_ROOT="$ROOT" SEND_RING_LOG="$dir/rings" AGENT_KIT_OBSERVATION_DIR="$AGENT_KIT_OBSERVATION_DIR" \
    bash "$dir/code/bin/fm-remote-secondmate-control.sh" send mate 'same durable request' fire-and-forget \
    > "$dir/out" 2> "$dir/err" || fail "resumed remote send failed: $(cat "$dir/err")"
  [ "$(wc -l < "$dir/rings" | tr -d ' ')" = 1 ] || fail 'resumed remote retry did not ring once'
  [ ! -e "$state/mate.inbox/002.msg" ] || fail 'resume duplicated the deferred remote record'
  pass 'remote send retains one durable record and returns 75 until its ring can resume'
)

test_owner_push_refreshes_and_tracks_phase() (
  local state destination server now count
  state=$(new_state publisher)
  export FM_HOME="${state%/state}" FM_ROOT_OVERRIDE="$ROOT"
  export FM_DATA_OVERRIDE="$FM_HOME/data"
  unset FM_OMNIGENT_SERVER
  destination="$TMP_ROOT/pushed-home"
  server=https://owner.example:8443
  now=$(date +%s)
  mkdir -p "$FM_HOME/data" "$destination"
  printf -- '- mate - remote (host: fixture; root: /fixture/code; home: /fixture/home; omnigent-server: %s; omnigent-host: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; scope: builds; projects: firstmate; added 2026-11-27)\n' "$server" > "$FM_HOME/data/secondmates.md"
  export FM_SSH_BIN="$TMP_ROOT/push-ssh" PUSH_DEST="$destination" PUSH_CODE="$ROOT" PUSH_SERVER="$server" PUSH_LOG="$TMP_ROOT/push.log"
  cat > "$FM_SSH_BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'push\n' >> "$PUSH_LOG"
FM_HOME="$PUSH_DEST" bash "$PUSH_CODE/bin/fm-upgrade-window.sh" receive "$PUSH_SERVER"
SH
  chmod +x "$FM_SSH_BIN"
  write_window job-push pausing 600
  fm_upgrade_window_publish "$state" "$now"
  FM_HOME="$destination" FM_OMNIGENT_SERVER="$server" fm_upgrade_window_read "$now" "$server"
  [ "$FM_UPGRADE_WINDOW_STATE" = active ] || fail 'phase push did not reach the destination'
  # A main-home doorbell uses its own file, without reverse SSH or a cache.
  fm_upgrade_window_read "$now" "$server"
  [ "$FM_UPGRADE_WINDOW_STATE" = active ] || fail 'owner did not read its own registered binding'
  fm_upgrade_window_publish "$state" "$((now + 1))"
  count=$(wc -l < "$PUSH_LOG" | tr -d ' ')
  [ "$count" = 1 ] || fail 'unchanged phase ignored refresh cadence'
  write_window job-push resumed 600 upgraded
  fm_upgrade_window_publish "$state" "$now"
  FM_HOME="$destination" FM_OMNIGENT_SERVER="$server" fm_upgrade_window_read "$now" "$server"
  [ "$FM_UPGRADE_WINDOW_STATE" = closed ] || fail 'phase change did not update remote copy'
  # Move the attempt marker backwards instead of manufacturing future owner time.
  { printf '%s\n' "$((now - 60))"; tail -n +2 "$state/.upgrade-window-push-mate"; } > "$state/marker"
  mv "$state/marker" "$state/.upgrade-window-push-mate"
  fm_upgrade_window_publish "$state" "$now"
  count=$(wc -l < "$PUSH_LOG" | tr -d ' ')
  [ "$count" = 3 ] || fail 'bounded refresh did not publish'
  printf '{broken' | FM_HOME="$destination" bash "$ROOT/bin/fm-upgrade-window.sh" receive "$server" >/dev/null 2>&1 && fail 'receiver accepted malformed envelope'
  FM_HOME="$destination" FM_OMNIGENT_SERVER="$server" fm_upgrade_window_read "$now" "$server"
  [ "$FM_UPGRADE_WINDOW_STATE" = closed ] || fail 'rejected input replaced good copy'
  printf null > "$WINDOW"
  fm_upgrade_window_publish "$state" "$now"
  FM_HOME="$destination" FM_OMNIGENT_SERVER="$server" fm_upgrade_window_read "$now" "$server"
  [ "$FM_UPGRADE_WINDOW_STATE" = unavailable ] || fail 'invalid owner data was published as absent'
  pass 'existing remote transport pushes phase changes, refreshes at 60s, and rejects malformed input'
)

fm_test_run \
  test_absent_window_defers_nothing \
  test_paused_window_defers_and_records \
  test_expired_window_defers_nothing \
  test_invalid_window_warns_and_defers_nothing \
  test_active_window_leaves_acknowledgement_to_kit \
  test_resumed_window_names_interrupted_workers_once \
  test_close_wakes_only_a_home_that_deferred \
  test_shared_ring_preserves_pending_record \
  test_secondmate_pause_preserves_recovery_budget \
  test_remote_window_uses_server_owner \
  test_owner_push_refreshes_and_tracks_phase \
  test_close_names_unlisted_stopped_runner \
  test_launch_rechecks_after_preflight \
  test_remote_recovery_checks_destination_before_attempt \
  test_close_respects_parking_and_proves_unbound_stop \
  test_remote_send_preserves_retryable_deferral
