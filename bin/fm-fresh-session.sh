#!/usr/bin/env bash
# Replace the owning Claude primary with a fresh Omnigent session.
# Usage: fm-fresh-session.sh [--dry-run]
# Run only after the /fresh skill has completed /stow successfully.
# Requires the current trusted Claude lock owner, Omnigent, jq, curl, and tmux.
# The old lock remains held until the token-bearing successor claims it through
# fm-lock.sh under .lock.acquire. No secondmate or worker invocation is allowed.
# Wait up to 180 seconds for that claim, then revoke permission under the same
# mutex. A failed launch leaves the old owner in charge. A failed old-session
# stop leaves the new owner in charge and reports its exact URL for recovery.
# --dry-run prints the home and paths without writing or contacting services.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-${SCRIPT_DIR%/bin}}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
fail() { printf 'error: fresh session: %s\n' "$*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'expected at most one argument'
case "${1:-}" in
  --dry-run)
    printf 'fresh session: home=%s; update %s/.lock and %s/.lock-session; create/remove %s/.fresh-handoff and %s/.fresh-claimed; launch firstmate; stop old session after claim\n' "$FM_HOME" "$STATE" "$STATE" "$STATE" "$STATE"
    exit ;;
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit ;;
  '') [ "$#" -eq 0 ] || fail 'unexpected argument' ;;
  *) fail 'expected --dry-run or no arguments' ;;
esac
[ -z "${FM_TASK_ID:-}${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ] || fail 'only the main primary can refresh'
[ "${OMNIGENT:-}" = 1 ] || fail 'requires a Claude Omnigent session'
for tool in jq curl tmux; do command -v "$tool" >/dev/null || fail "$tool is required"; done
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_trusted_session_id >/dev/null || fail 'requires trusted Claude identity'
fm_session_lock_owned_by_self "$STATE" || fail 'this session does not own the lock'
old=$(head -c 32 "$STATE/.lock")
old_session=${HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID:-}
[[ "$old_session" =~ ^[a-f0-9]{32}$ ]] || fail 'missing exact Omnigent session identity'
service=$("$SCRIPT_DIR/fm-omnigent.sh" run --dry-run claude) || fail 'Omnigent preflight failed; old owner retained'
server=$(printf '%s' "$service" | jq -er .server_url)
[[ "$server" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/?$ ]] || fail 'invalid local service URL'
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
snapshot=$(fm_run_timed 6 curl --silent --show-error --fail --max-time 5 --noproxy '*' --proto '=http' \
  "$server/v1/sessions/$old_session" | head -c 131073) || fail 'cannot verify old session'
[ "${#snapshot}" -le 131072 ] || fail 'oversized old-session response'
printf '%s' "$snapshot" | jq -e --arg id "$old_session" --arg claude "$CLAUDE_CODE_SESSION_ID" --arg home "$FM_HOME" '
  .id == $id and .external_session_id == $claude and .workspace == $home and
  .labels["omnigent.wrapper"] == "claude-code-native-ui"
' >/dev/null || fail 'old session does not match this Claude primary and home'
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
request="$STATE/.fresh-handoff"
receipt="$STATE/.fresh-claimed"
claim="$STATE/.lock.acquire"
held=0 token='' terminal=''
cleanup() {
  [ "$held" = 1 ] || { fm_lock_acquire_wait "$claim"; held=1; }
  if [ -n "$token" ] && [ -f "$request" ] && [ ! -L "$request" ] &&
    head -c 4097 "$request" | jq -e --arg token "$token" '.token == $token' >/dev/null 2>&1; then
    rm -f "$request" "$receipt"
  fi
  fm_lock_release "$claim"
  held=0
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$claim"; held=1
fm_session_lock_owned_by_self "$STATE" || fail 'ownership changed before launch'
[ ! -e "$request" ] && [ ! -L "$request" ] || fail 'another handoff is pending'
[ ! -e "$receipt" ] && [ ! -L "$receipt" ] || fail 'a prior handoff receipt needs inspection'
token=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
(umask 077; jq -cn --arg token "$token" --arg old "$old" --arg session "$old_session" --arg claude "$CLAUDE_CODE_SESSION_ID" \
  '{token:$token,old_pid:$old,old_session:$session,old_claude:$claude}' > "$request")
fm_lock_release "$claim"; held=0
terminal="fm-fresh-$token"
account_env=(-u CLAUDE_CONFIG_DIR)
if [ "${CLAUDE_CONFIG_DIR+x}" = x ]; then
  account_env=("CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR")
fi
printf -v command '%q ' env "${account_env[@]}" "FM_HOME=$FM_HOME" "FM_STATE_OVERRIDE=$STATE" \
  "FM_ROOT_OVERRIDE=${SCRIPT_DIR%/bin}" "FM_DATA_OVERRIDE=${FM_DATA_OVERRIDE:-$FM_HOME/data}" \
  "FM_CONFIG_OVERRIDE=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "FM_PROJECTS_OVERRIDE=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}" \
  "FM_BACKEND=${FM_BACKEND:-}" "FM_TASK_ID=" "FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=" "FM_TRACE_CONTEXT=" \
  "FM_FRESH_TOKEN=$token" bash "$SCRIPT_DIR/fm-omnigent.sh" run claude \
  'Continue as the main Firstmate in this home. Follow the normal session-start contract and recover the durable fleet state.'
if ! tmux new-session -d -s "$terminal" -c "$FM_HOME" "$command"; then
  fail 'replacement launch failed; old owner retained'
fi
wait_seconds=180
if [ "${FM_TEST_SEAM:-}" = 1 ]; then wait_seconds=${FM_TEST_FRESH_WAIT:-180}; fi
[[ "$wait_seconds" =~ ^[0-9]+$ ]] && [ "$wait_seconds" -ge 1 ] && [ "$wait_seconds" -le 180 ] || fail 'invalid claim deadline'
deadline=$(($(date +%s) + wait_seconds))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$receipt" ] && [ ! -L "$receipt" ]; then
    record=$(head -c 4097 "$receipt") || break
    [ "${#record}" -le 4096 ] || break
    printf '%s' "$record" | jq -se --arg token "$token" --arg old "$old" '
      length == 1 and (.[0] | .token == $token and .pid != $old and
        (.pid | type == "string" and test("^[0-9]+$")) and
        (.session | type == "string" and test("^[a-f0-9]{32}$")))
    ' >/dev/null || break
    new_pid=$(printf '%s' "$record" | jq -r .pid)
    new_session=$(printf '%s' "$record" | jq -r .session)
    if [ "$(head -c 32 "$STATE/.lock")" = "$new_pid" ] && fm_harness_pid_alive "$new_pid"; then
      fm_lock_acquire_wait "$claim"; held=1
      if [ "$(head -c 32 "$STATE/.lock")" != "$new_pid" ] || ! fm_harness_pid_alive "$new_pid"; then break; fi
      cleanup
      trap - EXIT
      printf 'fresh session owns the lock: %s/c/%s\n' "$server" "$new_session"
      fm_run_timed 6 curl --silent --show-error --fail --max-time 5 --noproxy '*' --proto '=http' \
        --header 'Content-Type: application/json' --request POST --data '{"type":"stop"}' \
        "$server/v1/sessions/$old_session/events" >/dev/null \
        || fail "new owner retained at $server/c/$new_session; old-session stop failed"
      exit 0
    fi
  fi
  sleep 0.1
done
# Serialize revocation with a claim that raced the deadline. Never kill a
# launcher if its session has become the owner in the meantime.
[ "$held" = 1 ] || { fm_lock_acquire_wait "$claim"; held=1; }
if [ "$(head -c 32 "$STATE/.lock")" = "$old" ]; then
  cleanup
  trap - EXIT
  tmux kill-session -t "$terminal" 2>/dev/null || true
  fail 'replacement did not claim the lock; old owner retained'
fi
cleanup
trap - EXIT
if env -u FM_FRESH_TOKEN bash "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1; then
  tmux kill-session -t "$terminal" 2>/dev/null || true
  fail 'replacement exited after claiming; old owner restored'
fi
fail 'ownership changed; old session left open, inspect fm-lock.sh status'
