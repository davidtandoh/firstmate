#!/usr/bin/env bash
# tests/fm-task-proc-lib.test.sh - table-driven tests for the finished-task
# process classifier (bin/fm-task-proc-lib.sh). Every case feeds a fake process
# listing; no test lists, signals, or otherwise touches a real process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-proc-lib.sh"

HOME_STATE=/Users/cap/workspace/firstmate/state
ID=job-a1
OTHER=job-b2
WT=/Users/cap/.treehouse/proj/3/proj
TMPROOT=/tmp/fm-$ID
INBOX=$HOME_STATE/$ID.inbox

classify() {  # <listing>
  printf '%s\n' "$1" | FM_TASK_PROC_INBOX=$INBOX FM_TASK_PROC_ID=$ID \
    FM_TASK_PROC_PROFILE=$TMPROOT FM_TASK_PROC_PATHS="$WT
$TMPROOT" fm_task_proc_classify
}

# Each row: <expected verdict: own|unclear|none>|<expected reason or ->|<listing line>
CASES=(
  "own|task-env|101 node /opt/homebrew/bin/chrome-devtools-axi bridge HOME=/Users/cap FM_TASK_INBOX=$INBOX PATH=/usr/bin"
  "own|browser-profile|102 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=0 --user-data-dir=$TMPROOT/browser-profile --headless"
  "own|browser-profile|103 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper --type=renderer --user-data-dir=/private$TMPROOT/browser-profile"
  "none|-|201 node bridge FM_TASK_INBOX=$HOME_STATE/$OTHER.inbox FM_TASK_ID=$OTHER"
  "none|-|202 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/fm-$OTHER/browser-profile"
  "none|-|203 node helper FM_TASK_INBOX=$INBOX.old"
  "none|-|301 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
  "none|-|302 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Default"
  "none|-|303 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  "none|-|304 /Applications/Codex.app/Contents/SharedSupport/SkyComputerUseService"
  "none|-|305 /System/Applications/Safari.app/Contents/MacOS/Safari"
  "unclear|protected-app|306 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/var/folders/x/chrome-profile FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|307 omnigent terminal program_status FM_TASK_INBOX=$INBOX"
  "unclear|task-id-without-inbox|401 node helper FM_TASK_ID=$ID HOME=/Users/cap"
  "unclear|path-mention|402 /usr/local/bin/code $WT"
  "unclear|path-mention|403 tail -f $TMPROOT/log.txt"
  "none|-|404 tail -f /tmp/fm-${ID}x/log.txt"
)

test_classifier_table() {
  local row expected reason line pid out got_kind got_reason
  for row in "${CASES[@]}"; do
    expected=${row%%|*}
    row=${row#*|}
    reason=${row%%|*}
    line=${row#*|}
    pid=${line%% *}
    out=$(classify "$line")
    if [ "$expected" = none ]; then
      [ -z "$out" ] || fail "pid $pid should be untouched and unlisted, got: $out"
      continue
    fi
    got_kind=$(printf '%s\n' "$out" | cut -f1)
    got_reason=$(printf '%s\n' "$out" | cut -f3)
    [ "$(printf '%s\n' "$out" | cut -f2)" = "$pid" ] || fail "pid $pid: wrong pid in $out"
    [ "$got_kind" = "$expected" ] || fail "pid $pid: expected $expected, got $got_kind ($out)"
    [ "$got_reason" = "$reason" ] || fail "pid $pid: expected reason $reason, got $got_reason"
  done
  pass "classifier closes only this task's own processes and lists unclear ones"
}

test_mixed_listing_and_exclusion() {
  local listing out
  listing=$(printf '%s\n' "${CASES[@]}" | cut -d'|' -f3-)
  out=$(classify "$listing" | awk -F '\t' '$1 == "own" { print $2 }' | tr '\n' ' ')
  assert_equals "$out" "101 102 103 " "own pids from a mixed listing"
  out=$(printf '%s\n' "$listing" | FM_TASK_PROC_EXCLUDE=$'101\n999' FM_TASK_PROC_INBOX=$INBOX \
    FM_TASK_PROC_ID=$ID FM_TASK_PROC_PROFILE=$TMPROOT fm_task_proc_classify \
    | awk -F '\t' '$1 == "own" { print $2 }' | tr '\n' ' ')
  assert_equals "$out" "102 103 " "excluded (own or ancestor) pids are never classified"
  pass "a mixed listing yields exactly the task's own pids and honors exclusions"
}

test_requires_inbox() {
  if printf '101 node FM_TASK_INBOX=\n' | FM_TASK_PROC_INBOX='' fm_task_proc_classify >/dev/null; then
    fail "classifier must refuse without the task inbox identity"
  fi
  pass "classifier refuses to run without the task's inbox identity"
}

fm_test_run test_classifier_table test_mixed_listing_and_exclusion test_requires_inbox
