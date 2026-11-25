#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/omnigent-fixture.sh"
TMP_ROOT=$(fm_test_tmproot fm-recorded-binding)
observer=
cleanup() {
  if [ -n "$observer" ]; then
    kill "$observer" 2>/dev/null || true
    wait "$observer" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/code/bin" "$TMP_ROOT/home/bin" "$TMP_ROOT/home/state/parent-route"
export HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$TMP_ROOT/code/bin/"
cp "$ROOT/bin/fm-remote-herdr-identity-lib.sh" "$TMP_ROOT/code/bin/"
mkdir -p "$HOME/.firstmate"
printf '%s\n' "$(cd "$TMP_ROOT/code" && pwd -P)" > "$HOME/.firstmate/remote-herdr-owner"
fm_test_omnigent_remote_upgrade_window "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH"
printf 'mate\n' > "$FM_HOME/.fm-secondmate-home"
: > "$FM_HOME/AGENTS.md"
for lib in fm-ff-lib.sh fm-pending-reply-lib.sh fm-task-inbox-lib.sh; do
  : > "$TMP_ROOT/code/bin/$lib"
done
cat > "$TMP_ROOT/code/bin/fm-backend.sh" <<'SH'
. "$FM_TEST_ROOT/bin/fm-task-inbox-lib.sh"
. "$FM_TEST_ROOT/bin/fm-composer-lib.sh"
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET=fm-remote:pane
}
fm_backend_meta_exact_value() { printf 'fm-remote\n'; }
fm_backend_agent_state() { printf alive; }
fm_backend_capture() { cat "$FM_HOME/screen"; }
fm_backend_composer_state() {
  fm_composer_classify_screen styled=1 "$(cat "$FM_HOME/screen")"
}
fm_backend_send_text_submit() { printf '%s\n' "$3" >> "$FM_HOME/rings"; }
SH
cat > "$TMP_ROOT/code/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_ROOT/code/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
. "$FM_TEST_ROOT/bin/fm-composer-lib.sh"
fm_composer_classify_screen styled=1 "$(cat "$FM_TEST_SCREEN")"
SH
cp "$TMP_ROOT/code/bin/fm-teardown.sh" "$TMP_ROOT/code/bin/fm-control.sh"
chmod +x "$TMP_ROOT/code/bin/"*.sh
control() {
  env -i PATH="$PATH" HOME="$HOME" FM_HOME="$FM_HOME" FM_TEST_ROOT="$ROOT" \
    FM_TEST_SCREEN="$FM_HOME/screen" bash "$TMP_ROOT/code/bin/fm-remote-secondmate-control.sh" "$@"
}
server=https://omnigent.example.ts.net
host=d5f2b09bd5744ef39fe34b4e58a35f5f
meta="$FM_HOME/state/parent-route/mate.meta"
printf 'omnigent=on\nomnigent_remote_server=%s\nomnigent_remote_host=%s\n' "$server" "$host" > "$meta"
printf '❯\nOmnigent: %s/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$server" > "$FM_HOME/screen"
printf 'wake the secondmate\n' | control send-stdin mate
[ -s "$FM_HOME/rings" ] || fail 'recorded remote binding did not permit the idle doorbell'
[ "$(control retire mate)" = empty ] || fail 'retirement did not restore the recorded composer binding'
case "$(control relaunch mate codex - -)" in
  empty*) ;;
  *) fail 'relaunch did not restore the recorded composer binding' ;;
esac
rm "$FM_HOME/rings"
printf '❯ actual draft\nOmnigent: %s/c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$server" > "$FM_HOME/screen"
printf 'another steer\n' | control send-stdin mate
[ ! -e "$FM_HOME/rings" ] || fail 'a genuine draft was submitted'
printf 'harness=codex\n' > "$meta"
printf '❯\n' > "$FM_HOME/screen"
printf 'unbound steer\n' | control send-stdin mate
[ -s "$FM_HOME/rings" ] || fail 'unbound endpoint behavior changed'
pass 'cleared-environment send and lifecycle requests recover the recorded binding'

fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-wake-lib.sh"
for server in https://omnigent.example.ts.net http://127.0.0.1:6767; do
  printf 'spawn_gen=s.binding.1\nomnigent=on\n' > "$meta"
  parent=
  if [[ "$server" = https:* ]]; then
    parent=$server
    printf 'omnigent_remote_server=%s\nomnigent_remote_host=%s\n' "$server" "$host" >> "$meta"
  fi
  lock=$(fm_meta_lock_path "$meta")
  fm_lock_acquire_wait "$lock"
  FM_OMNIGENT_SERVER="$parent" FM_OMNIGENT_HOST='' FM_OMNIGENT_RECORD_META="$meta" \
    FM_OMNIGENT_RECORD_GEN=s.binding.1 FM_OMNIGENT_ATTACH_PID=12345 FM_OMNIGENT_ATTACH_START=identity \
    bash "$ROOT/bin/fm-omnigent.sh" _title-session "$server" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      claude title 1 > "$TMP_ROOT/title-out" 2> "$TMP_ROOT/title-error" &
  observer=$!
  pending="$FM_HOME/state/parent-route/.mate.omnigent.s.binding.1.meta"
  for ((attempt=0; attempt<100; attempt++)); do
    [ -z "$(fm_meta_get "$pending" omnigent_session)" ] || break
    sleep 0.05
  done
  [ -f "$pending" ] || fail 'observer did not publish a session handoff'
  [ -z "$(fm_meta_get "$meta" omnigent_session)" ] || fail 'observer bypassed the metadata lock'
  env -u FM_OMNIGENT_SERVER -u FM_OMNIGENT_HOST \
    bash "$ROOT/bin/fm-omnigent.sh" capture --record-locked "$meta"
  [ "$(fm_meta_get "$meta" omnigent_session)" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] || fail 'capture lost the session'
  [ "$(fm_meta_get "$meta" omnigent_attach_pid)" = 12345 ] || fail 'capture lost the attach pid'
  [ "$(fm_meta_get "$meta" omnigent_attach_start)" = identity ] || fail 'capture lost the attach identity'
  fm_lock_release "$lock"
  wait "$observer"
  observer=
done
pass 'locked capture consumes remote and local observer handoffs without a request binding'

for mode in slow wrong-harness; do
  printf 'spawn_gen=s.binding.2\nomnigent=on\n' > "$meta"
  lock=$(fm_meta_lock_path "$meta")
  fm_lock_acquire_wait "$lock"
  OMNI_TITLE_MODE=$mode FM_TEST_OMNIGENT_NAMING_BUDGET=6 \
    FM_OMNIGENT_RECORD_META="$meta" FM_OMNIGENT_RECORD_GEN=s.binding.2 \
    bash "$ROOT/bin/fm-omnigent.sh" _title-session http://127.0.0.1:6767 \
      aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa claude title 1 > "$TMP_ROOT/title-out" 2> "$TMP_ROOT/title-error" &
  observer=$!
  pending="$FM_HOME/state/parent-route/.mate.omnigent.s.binding.2.meta"
  for ((attempt=0; attempt<100; attempt++)); do
    [ ! -f "$pending" ] || break
    sleep 0.01
  done
  [ -f "$pending" ] || fail 'observer did not publish before the identity GET'
  bash "$ROOT/bin/fm-omnigent.sh" capture --record-locked "$meta"
  [ -n "$(fm_meta_get "$meta" omnigent_unnamed)" ] || fail 'capture lost the unverified launch'
  [ -z "$(fm_meta_get "$meta" omnigent_session)" ] || fail 'capture promoted an unverified identity'
  [ "$(bash "$ROOT/bin/fm-omnigent.sh" probe "$meta")" = unknown ] || fail 'probe used an unverified identity'
  if [ "$mode" = slow ]; then
    OMNI_SESSION_STATE=runner-gone bash "$ROOT/bin/fm-omnigent.sh" archive --record-locked "$meta" > "$TMP_ROOT/archive-out"
    jq -se 'length == 1 and .[0].body == {archived:true}' "$TMP_ROOT/service/archived.jsonl" >/dev/null \
      || fail 'early retirement leaked the Claude session'
  fi
  fm_lock_release "$lock"
  if wait "$observer"; then fail 'failed naming unexpectedly succeeded'; fi
  observer=
  if [ "$mode" = wrong-harness ]; then
    [ -z "$(fm_meta_get "$meta" omnigent_unnamed)" ] || fail 'refuted identity remained in the task record'
    [ ! -e "$pending" ] || fail 'refuted identity remained in the handoff'
  fi
done
pass 'early retirement verifies the Claude fallback and refutation removes captured identities'
for wrapper in claude-code codex kiro antigravity unsupported claude; do
  printf 'omnigent_unnamed=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa http://127.0.0.1:6767 %s-native-ui 1 -\n' "$wrapper" > "$meta"
  rc=0
  bash "$ROOT/bin/fm-omnigent.sh" archive --dry-run "$meta" > "$TMP_ROOT/out" 2> "$TMP_ROOT/error" || rc=$?
  case "$wrapper" in
    unsupported|claude) [ "$rc" = 1 ] || fail "unsupported wrapper accepted: $wrapper" ;;
    *) [ "$rc" = 0 ] || fail "supported wrapper rejected: $wrapper" ;;
  esac
done
pass 'fallback accepts exactly the four supported native wrappers'
