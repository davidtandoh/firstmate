#!/usr/bin/env bash
set -euo pipefail
E=/Users/davidtandoh/.no-mistakes/evidence/01M59P192KW7VX65HF78KQQV6X
LAB=$(mktemp -d "$PWD/.session-validation.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data"
export FM_SUPERVISION_ACTOR=main
unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK STATE FM_ROOT
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data"
touch "$LAB/config/supervision-host-off"
printf '%s\n' "$$" > "$LAB/state/.lock"
set_age() { perl -e 'utime(time-$ARGV[0],time-$ARGV[0],$ARGV[1]) or die $!' "$1" "$LAB/state/.lock"; }
drive() {
  local name=$1
  bash bin/fm-wake-drain.sh > "$E/$name.stdout" 2> "$E/$name.stderr"
  printf '\n[%s] exit=0\n' "$name"
  cat "$E/$name.stdout"
  if [ -f "$LAB/state/.fresh-session-prompt" ]; then printf 'receipt='; cat "$LAB/state/.fresh-session-prompt"; else printf 'receipt=absent\n'; fi
}
set_age 169200
drive young
! grep -q 'SESSION SUGGESTION' "$E/young.stdout"
set_age 176400
drive long
grep -q 'consider /stow and starting a fresh session.*optional' "$E/long.stdout"
drive repeated
! grep -q 'SESSION SUGGESTION' "$E/repeated.stdout"
set_age 180000
drive new-generation
grep -q 'SESSION SUGGESTION' "$E/new-generation.stdout"
rm "$LAB/state/.fresh-session-prompt"
printf '1\n' > "$LAB/state/.branch-eligible-rows"
identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$PWD" "$$")
printf 'fm-branch-eligible-owner-v1\n%s\n%s\nmanual-validation\n' "$$" "$identity" > "$LAB/state/.branch-eligible-owner"
export FM_SUPERVISION_ACTOR=branch
drive branch
! grep -q 'SESSION SUGGESTION' "$E/branch.stdout"
test ! -e "$LAB/state/.fresh-session-prompt"
export FM_SUPERVISION_ACTOR=main
touch "$LAB/.fm-secondmate-parent"
drive secondmate
! grep -q 'SESSION SUGGESTION' "$E/secondmate.stdout"
rm "$LAB/.fm-secondmate-parent"
printf 'invalid\n' > "$LAB/state/.lock"
set_age 180000
drive malformed
! grep -q 'SESSION SUGGESTION' "$E/malformed.stdout"
rm "$LAB/state/.lock"
drive absent
! grep -q 'SESSION SUGGESTION' "$E/absent.stdout"
printf '\nAll direct CLI assertions passed. No harness or daemon was launched; lock ages were set explicitly.\n'
