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
  env -i PATH="$PATH" HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home" \
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
