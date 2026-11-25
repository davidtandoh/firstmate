#!/usr/bin/env bash
# Behavior tests for bin/fm-upgrade-window-lib.sh, Firstmate's reader of the
# Agent Kit's Omnigent upgrade pause window: an active window defers and is
# held without acknowledgement, an expired or absent window defers nothing, an
# unreadable one warns and defers nothing, and a closed job raises one wake for
# a home that deferred work or owns an interrupted session, naming those tasks.
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
  local state rc=0
  state=$(new_state remote)
  mkdir -p "$TMP_ROOT/remote-bin"
  cat > "$TMP_ROOT/remote-bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SSH_LOG"
[ "${SSH_FAIL:-0}" = 0 ] || exit 255
cat "$SSH_WINDOW"
SH
  chmod +x "$TMP_ROOT/remote-bin/ssh"
  export PATH="$TMP_ROOT/remote-bin:$PATH" SSH_WINDOW="$TMP_ROOT/remote-window.json" SSH_LOG="$TMP_ROOT/ssh.log"
  write_window job-remote pausing 600
  cp "$WINDOW" "$SSH_WINDOW"
  rm "$WINDOW"
  fm_upgrade_window_gate 'remote worker' "$state" https://owner.example:8443 2>/dev/null || rc=$?
  [ "$rc" = 75 ] || fail 'remote server pause was bypassed by absent local window'
  [ "$(cat "$state/.upgrade-window-deferred")" = job-remote ] || fail 'remote pause not recorded'
  grep -q -- '-- owner.example ' "$SSH_LOG" || fail 'remote read used the wrong server owner'
  write_window job-remote resumed 600 upgraded
  cp "$WINDOW" "$SSH_WINDOW"
  fm_upgrade_window_gate 'remote worker' "$state" https://owner.example:8443 || fail 'remote resume did not admit work'
  rc=0
  SSH_FAIL=1 fm_upgrade_window_gate 'remote worker' "$state" https://owner.example:8443 2>/dev/null || rc=$?
  [ "$rc" = 75 ] || fail 'unavailable remote owner admitted work'
  pass 'remote binding honors its owner window and fails closed on unavailable reads'
)

test_close_names_unlisted_stopped_runner() (
  local state
  state=$(new_state stopped)
  . "$ROOT/tests/omnigent-fixture.sh"
  fm_test_omnigent_service "$TMP_ROOT/probe-service" "$TMP_ROOT/probe-tools"
  export PATH="$TMP_ROOT/probe-tools:$PATH" OMNI_SESSION_STATE=runner-gone
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
  test_close_names_unlisted_stopped_runner \
  test_launch_rechecks_after_preflight \
  test_remote_recovery_checks_destination_before_attempt
