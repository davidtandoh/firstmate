#!/usr/bin/env bash
# Behavior tests for bin/fm-upgrade-window-lib.sh, Firstmate's reader of the
# Agent Kit's Omnigent upgrade pause window: an active window defers and is
# acknowledged once per job, an expired or absent window defers nothing, an
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

test_active_window_is_acknowledged_once() {
  local state first
  state=$(new_state ack)
  rm -f "$ACK"
  write_window job-a pausing 600
  fm_upgrade_window_supervise "$state"
  [ -z "$FM_UPGRADE_WINDOW_REASON" ] || fail 'an active window woke the supervisor'
  jq -e '.job == "job-a" and (.paused_at | type == "number")' "$ACK" >/dev/null || fail 'acknowledgement missing or malformed'
  [ "$(stat -f %Lp "$ACK" 2>/dev/null || stat -c %a "$ACK")" = 600 ] || fail 'acknowledgement is not owner-only'
  first=$(cat "$ACK")
  printf '{"job":"job-a","paused_at":1}\n' > "$ACK"
  fm_upgrade_window_supervise "$state"
  [ "$(jq -r .paused_at "$ACK")" = 1 ] || fail 'acknowledgement was rewritten for the same job'
  write_window job-b pausing 600
  fm_upgrade_window_supervise "$state"
  [ "$(jq -r .job "$ACK")" = job-b ] || fail 'a new job was not acknowledged'
  [ -n "$first" ] || fail 'first acknowledgement was empty'
  pass 'an active window is acknowledged once per job without waking the supervisor'
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
    'check: omnigent-upgrade job-r closed (upgraded);'*'relaunch interrupted workers with bin/fm-control.sh <task> relaunch: w1') ;;
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

fm_test_run \
  test_absent_window_defers_nothing \
  test_paused_window_defers_and_records \
  test_expired_window_defers_nothing \
  test_invalid_window_warns_and_defers_nothing \
  test_active_window_is_acknowledged_once \
  test_resumed_window_names_interrupted_workers_once \
  test_close_wakes_only_a_home_that_deferred
