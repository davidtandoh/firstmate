#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "$ROOT/tests/.remote-capture.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/code/bin" "$TMP_ROOT/home/bin" "$TMP_ROOT/user"
cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$TMP_ROOT/code/bin/"
printf 'mate\n' > "$TMP_ROOT/home/.fm-secondmate-home"
: > "$TMP_ROOT/home/AGENTS.md"
for lib in fm-ff-lib.sh fm-pending-reply-lib.sh fm-task-inbox-lib.sh; do
  : > "$TMP_ROOT/code/bin/$lib"
done
cat > "$TMP_ROOT/code/bin/fm-backend.sh" <<'SH'
. "$FM_TEST_ROOT/bin/fm-backend.sh"
fm_backend_agent_state() { cat "$FM_TEST_ENDPOINT_STATE"; }
fm_backend_kill() {
  [ "${FM_TEST_CLOSE_FAIL:-0}" != 1 ] || return 1
  printf 'missing\n' > "$FM_TEST_ENDPOINT_STATE"
}
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET=fm-remote:pane
}
fm_backend_meta_exact_value() { printf 'fm-remote\n'; }
fm_backend_capture() {
  [ "$*" = 'herdr fm-remote:pane 20 fm-mate' ] || return 98
  cat "$FM_TEST_PAYLOAD" || return $?
  printf 'complete\n' > "$FM_TEST_COMPLETED"
  return "$FM_TEST_BACKEND_RC"
}
SH

capture() {
  env -i PATH="$PATH" HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home" FM_TEST_ROOT="$ROOT" \
    FM_TEST_PAYLOAD="$TMP_ROOT/payload" FM_TEST_COMPLETED="$TMP_ROOT/completed" \
    FM_TEST_BACKEND_RC="$1" \
    bash "$TMP_ROOT/code/bin/fm-remote-secondmate-control.sh" capture mate \
    > "$TMP_ROOT/output"
}

printf 'short capture\n' > "$TMP_ROOT/payload"
capture 0
cmp "$TMP_ROOT/payload" "$TMP_ROOT/output"
printf 'ok - short capture is unchanged\n'

for ((i = 0; i < 128; i++)); do
  printf '%8192s' ''
done > "$TMP_ROOT/payload"
head -c 65536 "$TMP_ROOT/payload" > "$TMP_ROOT/expected"
rm "$TMP_ROOT/completed"
capture 0
[ -f "$TMP_ROOT/completed" ]
[ "$(wc -c < "$TMP_ROOT/output" | tr -d ' ')" = 65536 ]
cmp "$TMP_ROOT/expected" "$TMP_ROOT/output"
printf 'ok - oversized capture drains successfully and retains exactly 65536 bytes\n'

for size in empty short large; do
  case "$size" in
    empty) : > "$TMP_ROOT/payload" ;;
    short) printf 'partial capture\n' > "$TMP_ROOT/payload" ;;
    large) for ((i = 0; i < 128; i++)); do printf '%8192s' ''; done > "$TMP_ROOT/payload" ;;
  esac
  rc=0
  capture 37 || rc=$?
  [ "$rc" -eq 37 ]
  head -c 65536 "$TMP_ROOT/payload" > "$TMP_ROOT/expected"
  cmp "$TMP_ROOT/expected" "$TMP_ROOT/output"
  printf 'ok - %s failing capture preserves backend exit status\n' "$size"
done

. "$ROOT/tests/omnigent-fixture.sh"
fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
mkdir -p "$TMP_ROOT/home/state/parent-route"
cat > "$TMP_ROOT/code/bin/fm-omnigent.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = stop-attach ]; then
  printf 'dead\n' > "$FM_TEST_ENDPOINT_STATE"
  printf 'stopped\n' > "$FM_HOME/attach-stopped"
  exit 0
fi
exec bash "$FM_TEST_ROOT/bin/fm-omnigent.sh" "$@"
SH
cat > "$TMP_ROOT/code/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$(cat "$FM_TEST_ENDPOINT_STATE")" = missing ] || exit 1
if [ -f "$FM_HOME/../serve/archived.jsonl" ]; then
  cp "$FM_HOME/../serve/archived.jsonl" "$FM_STATE_OVERRIDE/archived-before-spawn"
fi
printf 'harness=claude\nmodel=default\neffort=default\nherdr_session=fm-remote\n' > "$FM_STATE_OVERRIDE/mate.meta"
printf 'spawned\n' > "$FM_STATE_OVERRIDE/spawned"
SH
chmod +x "$TMP_ROOT/code/bin/fm-omnigent.sh" "$TMP_ROOT/code/bin/fm-spawn.sh"
remote_control() {
  env -i PATH="$TMP_ROOT/tools:$PATH" HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home" \
    FM_TEST_ROOT="$ROOT" FM_TEST_ENDPOINT_STATE="$TMP_ROOT/endpoint-state" \
    FM_TEST_CLOSE_FAIL="${FM_TEST_CLOSE_FAIL:-0}" OMNI_SESSION_STATE="${OMNI_SESSION_STATE:-alive}" \
    OMNI_ARCHIVE_MODE="${OMNI_ARCHIVE_MODE:-ok}" \
    bash "$TMP_ROOT/code/bin/fm-remote-secondmate-control.sh" "$@"
}
reset_remote_meta() {
  printf 'harness=claude\nspawn_gen=s1.1.1\nomnigent=on\nomnigent_session=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nomnigent_server=http://127.0.0.1:6767\n' \
    > "$TMP_ROOT/home/state/parent-route/mate.meta"
  rm -f "$TMP_ROOT/serve/archived.jsonl" "$TMP_ROOT/home/state/parent-route/spawned" \
    "$TMP_ROOT/home/state/parent-route/archived-before-spawn" "$TMP_ROOT/home/attach-stopped"
}
for session_state in alive runner-gone missing server-error; do
  reset_remote_meta
  printf 'alive\n' > "$TMP_ROOT/endpoint-state"
  expected=alive
  case "$session_state" in runner-gone|missing) expected=dead ;; esac
  [ "$(OMNI_SESSION_STATE="$session_state" remote_control state mate)" = "$expected" ]
done
printf 'ok - host-local state overlays the recorded Omnigent session verdict\n'
for pane_state in alive dead missing; do
  for archive_mode in ok http-error; do
    reset_remote_meta
    printf '%s\n' "$pane_state" > "$TMP_ROOT/endpoint-state"
    OMNI_SESSION_STATE=runner-gone OMNI_ARCHIVE_MODE="$archive_mode" remote_control launch mate claude - - herdr \
      > "$TMP_ROOT/launch-out" 2> "$TMP_ROOT/launch-error"
    [ -f "$TMP_ROOT/home/state/parent-route/spawned" ]
    if [ "$pane_state" = alive ]; then [ -f "$TMP_ROOT/home/attach-stopped" ]; fi
    if [ "$archive_mode" = ok ]; then
      jq -se 'length == 1 and .[0].id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .[0].body == {archived:true}' \
        "$TMP_ROOT/home/state/parent-route/archived-before-spawn" > /dev/null
    else
      grep -q 'warning: Omnigent archive' "$TMP_ROOT/launch-error"
    fi
  done
done
reset_remote_meta
printf 'dead\n' > "$TMP_ROOT/endpoint-state"
if FM_TEST_CLOSE_FAIL=1 remote_control launch mate claude - - herdr > "$TMP_ROOT/launch-out" 2> "$TMP_ROOT/launch-error"; then
  printf 'failed close allowed replacement\n' >&2
  exit 1
fi
[ ! -e "$TMP_ROOT/serve/archived.jsonl" ] && [ ! -e "$TMP_ROOT/home/state/parent-route/spawned" ]
printf 'ok - host-local launch archives stopped sessions before replacement and only warns on archive failure\n'
