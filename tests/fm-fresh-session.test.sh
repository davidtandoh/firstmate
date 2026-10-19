#!/usr/bin/env bash
# Fresh-session launch ordering, ownership transfer, and rollback through public commands.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fresh-session)
old_pid='' new_pid=''
real_tmux=$(command -v tmux)
tmux_socket="fm-fresh-test-$$"
export REAL_TMUX=$real_tmux TMUX_SOCKET=$tmux_socket
cleanup() {
  [ -z "$old_pid" ] || kill "$old_pid" 2>/dev/null || true
  [ -z "$new_pid" ] || kill "$new_pid" 2>/dev/null || true
  "$real_tmux" -L "$tmux_socket" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
sleep 300 & old_pid=$!
sleep 300 & new_pid=$!
export OLD_PID=$old_pid NEW_PID=$new_pid
export HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/main" FM_STATE_OVERRIDE="$TMP_ROOT/main/state"
export CLAUDE_PID=$old_pid CLAUDE_CODE_SESSION_ID=old-session
export HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export FM_TEST_FRESH_WAIT=2 OMNIGENT=1
mkdir -p "$FM_HOME/bin" "$FM_HOME/state" "$HOME" "$TMP_ROOT/tools"
for script in fm-cursor-lib.sh fm-hook-host-lib.sh fm-fresh-session.sh fm-lock.sh fm-session-lock-lib.sh fm-wake-lib.sh fm-path-lib.sh fm-timeout-lib.sh; do
  cp "$ROOT/bin/$script" "$FM_HOME/bin/$script"
done
cat > "$TMP_ROOT/tools/ps" <<'SH'
#!/usr/bin/env bash
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) field=$2; shift 2 ;; -p) pid=$2; shift 2 ;; *) shift ;; esac
done
case "$field:$pid" in
  comm=:"$OLD_PID"|comm=:"$NEW_PID") echo claude ;;
  args=:"$OLD_PID"|args=:"$NEW_PID") echo claude ;;
  ppid=:"$OLD_PID"|ppid=:"$NEW_PID") echo 1 ;;
  comm=:*) echo bash ;;
  args=:*) echo bash ;;
  ppid=:*) echo "$CLAUDE_PID" ;;
esac
SH
cat > "$FM_HOME/bin/fm-omnigent.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = start ]; then exit 99; fi
if [ "$2" = --dry-run ]; then
  echo preflight >> "$FM_HOME/events"
  [ "${CASE:-}" != preflight-fail ] || exit 1
  echo '{"server_url":"http://127.0.0.1:6767"}'
else
  printf '%s\n' "$FM_FRESH_TOKEN" > "$FM_HOME/fresh-token"
  jq -cn --arg present "${CLAUDE_CONFIG_DIR+x}" --arg value "${CLAUDE_CONFIG_DIR:-}" \
    '{present:$present,value:$value}' > "$FM_HOME/account-environment"
  echo launch >> "$FM_HOME/events"
  [ "$(cat "$FM_HOME/state/.lock")" = "$OLD_PID" ]
  [ "${CASE:-}" != launch-fail ] || exit 1
  [ "${CASE:-}" != timeout ] || exit 0
  export CLAUDE_PID=$NEW_PID CLAUDE_CODE_SESSION_ID=new-session
  export HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  bash "$FM_HOME/bin/fm-lock.sh"
  echo claimed >> "$FM_HOME/events"
  if [ "${CASE:-}" = claim-dies ]; then kill "$NEW_PID"; sleep 0.1; fi
fi
SH
cat > "$TMP_ROOT/tools/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${REAL_TMUX_LAUNCH:-}" = 1 ]; then
  exec "$REAL_TMUX" -L "$TMUX_SOCKET" "$@"
fi
if [ "$1" = new-session ]; then
  while [ "$#" -gt 1 ]; do shift; done
  bash -c "$1"
fi
SH
cat > "$TMP_ROOT/tools/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' POST '*)
    [ "$(cat "$FM_HOME/state/.lock")" = "$NEW_PID" ]
    [ "$(cat "$FM_HOME/state/.lock-session")" = new-session ]
    echo stop >> "$FM_HOME/events"
    [ "${CASE:-}" != stop-fail ] || exit 22
    echo '{"queued":false}' ;;
  *) echo '{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","external_session_id":"old-session","workspace":"'"$FM_HOME"'","labels":{"omnigent.wrapper":"claude-code-native-ui"}}' ;;
esac
SH
chmod +x "$TMP_ROOT/tools/"* "$FM_HOME/bin/"*.sh
export PATH="$TMP_ROOT/tools:$PATH"
reset() {
  printf '%s\n' "$OLD_PID" > "$FM_HOME/state/.lock"
  echo old-session > "$FM_HOME/state/.lock-session"
  rm -f "$FM_HOME/events" "$FM_HOME/state/.fresh-handoff" "$FM_HOME/state/.fresh-claimed"
}
reset
bash "$FM_HOME/bin/fm-fresh-session.sh" --dry-run > "$TMP_ROOT/out"
[ ! -e "$FM_HOME/events" ] || fail 'dry-run launched or probed a service'
[ "$(cat "$FM_HOME/state/.lock")" = "$OLD_PID" ] || fail 'dry-run changed ownership'
for CASE in preflight-fail launch-fail timeout; do
  export CASE
  reset
  if bash "$FM_HOME/bin/fm-fresh-session.sh" > "$TMP_ROOT/out" 2>&1; then fail "$CASE succeeded"; fi
  case "$CASE" in
    preflight-fail) expected='preflight failed' ;;
    launch-fail) expected='launch failed' ;;
    timeout) expected='did not claim' ;;
  esac
  grep -q "$expected" "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail "$CASE failed for an unrelated reason"; }
  [ "$(cat "$FM_HOME/state/.lock")" = "$OLD_PID" ] || fail "$CASE lost old owner"
  [ "$(cat "$FM_HOME/state/.lock-session")" = old-session ] || fail "$CASE lost old session"
  ! grep -q stop "$FM_HOME/events" || fail "$CASE stopped old session"
  [ ! -e "$FM_HOME/state/.fresh-handoff" ] || fail "$CASE retained takeover permission"
done
pass 'dry-run and failed launches preserve the old owner and never close it'
unset CASE
reset
bash "$FM_HOME/bin/fm-fresh-session.sh" > "$TMP_ROOT/out" 2>&1 || { cat "$TMP_ROOT/out"; fail "successful handoff failed"; }
printf 'preflight\nlaunch\nclaimed\nstop\n' > "$TMP_ROOT/expected"
cmp "$TMP_ROOT/expected" "$FM_HOME/events" || fail 'handoff order differs'
pass 'replacement claims ownership before old-session stop'
[ ! -e "$FM_HOME/state/.fresh-handoff" ] || fail 'successful handoff retained its request'
kill "$NEW_PID"
wait "$NEW_PID" 2>/dev/null || true
if ! CLAUDE_PID=$OLD_PID CLAUDE_CODE_SESSION_ID=new-session \
  HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  FM_FRESH_TOKEN="$(cat "$FM_HOME/fresh-token")" \
  bash "$FM_HOME/bin/fm-lock.sh" > "$TMP_ROOT/out" 2>&1; then
  cat "$TMP_ROOT/out"
  fail 'completed handoff blocked stale-anchor recovery'
fi
[ "$(cat "$FM_HOME/state/.lock")" = "$OLD_PID" ] || fail 'recovery did not publish the recycled anchor'
[ "$(cat "$FM_HOME/state/.lock-session")" = new-session ] || fail 'recovery lost the replacement session'
[ ! -e "$FM_HOME/state/.fresh-claimed" ] || fail 'stale recovery published a takeover receipt'
pass 'completed handoff permits stale-anchor recovery with the retained token'
sleep 300 & new_pid=$!
export NEW_PID=$new_pid

CLAUDE_CONFIG_DIR="$TMP_ROOT/server-account" "$REAL_TMUX" -L "$TMUX_SOCKET" \
  -f /dev/null new-session -d -s anchor 'sleep 300'
"$REAL_TMUX" -L "$TMUX_SOCKET" set-option -g default-shell /bin/bash
for server_account in set unset; do
  if [ "$server_account" = set ]; then
    "$REAL_TMUX" -L "$TMUX_SOCKET" set-environment -g CLAUDE_CONFIG_DIR "$TMP_ROOT/server-account"
  else
    "$REAL_TMUX" -L "$TMUX_SOCKET" set-environment -gu CLAUDE_CONFIG_DIR
  fi
  for caller_account in set unset empty; do
    reset
    case "$caller_account" in
      set) export CLAUDE_CONFIG_DIR="$TMP_ROOT/current account's config" ;;
      unset) unset CLAUDE_CONFIG_DIR ;;
      empty) export CLAUDE_CONFIG_DIR= ;;
    esac
    jq -cn --arg present "${CLAUDE_CONFIG_DIR+x}" --arg value "${CLAUDE_CONFIG_DIR:-}" \
      '{present:$present,value:$value}' > "$TMP_ROOT/expected-account"
    if ! REAL_TMUX_LAUNCH=1 bash "$FM_HOME/bin/fm-fresh-session.sh" > "$TMP_ROOT/out" 2>&1; then
      cat "$TMP_ROOT/out"
      fail "$caller_account caller account with $server_account server account failed"
    fi
    cmp "$TMP_ROOT/expected-account" "$FM_HOME/account-environment" \
      || fail "$caller_account caller account changed across $server_account tmux environment"
  done
done
"$REAL_TMUX" -L "$TMUX_SOCKET" kill-server
unset CLAUDE_CONFIG_DIR
pass 'existing tmux server preserves set, unset, and empty caller account environments'

reset
if CASE=stop-fail bash "$FM_HOME/bin/fm-fresh-session.sh" > "$TMP_ROOT/out" 2>&1; then fail 'failed stop hidden'; fi
[ "$(cat "$FM_HOME/state/.lock")" = "$NEW_PID" ] || fail 'failed close stole new ownership'
pass 'failed old-session stop preserves replacement ownership and reports failure'
for case_name in missing-token wrong-token wrong-owner same-claude same-omnigent revoked oversized; do
  reset
  token=0123456789abcdef
  jq -cn --arg token "$token" --arg pid "$OLD_PID" \
    '{token:$token,old_pid:$pid,old_claude:"old-session",old_session:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$FM_HOME/state/.fresh-handoff"
  export CLAUDE_PID=$NEW_PID CLAUDE_CODE_SESSION_ID=new-session
  export HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  case "$case_name" in
    missing-token) token= ;;
    wrong-token) token=wrong ;;
    wrong-owner)
      jq '.old_pid = "1"' "$FM_HOME/state/.fresh-handoff" > "$TMP_ROOT/request"
      mv "$TMP_ROOT/request" "$FM_HOME/state/.fresh-handoff" ;;
    same-claude) CLAUDE_CODE_SESSION_ID=old-session; echo unrelated > "$FM_HOME/state/.lock-session" ;;
    same-omnigent) HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    revoked) rm "$FM_HOME/state/.fresh-handoff" ;;
    oversized) printf '%5000s' '' >> "$FM_HOME/state/.fresh-handoff" ;;
  esac
  previous=$(cat "$FM_HOME/state/.lock")
  if FM_FRESH_TOKEN="$token" bash "$FM_HOME/bin/fm-lock.sh" > "$TMP_ROOT/out" 2>&1; then fail "$case_name takeover accepted"; fi
  [ "$(cat "$FM_HOME/state/.lock")" = "$previous" ] || fail "$case_name changed the lock"
done
pass 'ordinary, mismatched, revoked, oversized, and same-session claims cannot take over'

export CLAUDE_PID=$OLD_PID CLAUDE_CODE_SESSION_ID=old-session
export HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
reset
if CASE=claim-dies bash "$FM_HOME/bin/fm-fresh-session.sh" > "$TMP_ROOT/out" 2>&1; then fail 'dead replacement succeeded'; fi
[ "$(cat "$FM_HOME/state/.lock")" = "$OLD_PID" ] || fail 'dead replacement left the home without an owner'
[ "$(cat "$FM_HOME/state/.lock-session")" = old-session ] || fail 'restored owner has the wrong session'
! grep -q stop "$FM_HOME/events" || fail 'dead replacement caused old-session stop'
grep -q 'old owner restored' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out"; fail 'restoration was not reported'; }
pass 'replacement death after claim restores the live original owner'
