#!/usr/bin/env bash
# tests/fm-task-proc-lib.test.sh - table-driven tests for the finished-task
# process classifier (bin/fm-task-proc-lib.sh). Every case feeds a fake process
# listing; no test lists, signals, or otherwise touches a real process.
set -euo pipefail

ps() {
  case "$*" in *lstart=*) printf 'Sun Nov 1 12:00:00 2026 fixture\n' ;; esac
}
kill() { fail "unexpected process signal: $*"; }
export -f ps kill
export FM_PROC_ROOT_OVERRIDE="$PWD/.fixture-proc-not-present"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-proc-lib.sh"

HOME_STATE=/Users/cap/workspace/firstmate/state
ID=job-a1
OTHER=job-b2
WT=/Users/cap/.treehouse/proj/3/proj
TMPROOT=/tmp/$(fm_task_proc_browser_session /Users/cap/workspace/firstmate "$ID")
PROFILE=$TMPROOT/browser-profile
INBOX=$HOME_STATE/$ID.inbox

classify() {  # <listing>
  printf '%s\n' "$1" | FM_TASK_PROC_INBOX=$INBOX FM_TASK_PROC_ID=$ID \
    FM_TASK_PROC_PROFILE=$PROFILE FM_TASK_PROC_PATHS="$WT
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
  "own|task-env|405 node helper FM_OMNIGENT=off FM_TASK_INBOX=$INBOX"
  "own|task-env|406 node helper FM_OMNIGENT=on FM_TASK_INBOX=$INBOX"
  "own|task-env|407 node helper --label=omnigent-chatgpt-6767 FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|408 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|409 /Applications/Codex.app/Contents/SharedSupport/SkyComputerUseService FM_TASK_INBOX=$INBOX"
  "unclear|path-mention|410 chrome --user-data-dir=$PROFILE/other"
  "unclear|path-mention|411 chrome --user-data-dir=${PROFILE}x"
  "unclear|protected-app|420 hermes FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|421 mlflow FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|422 tailscale FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|423 /System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|424 fm-remote-job-worker FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|425 server-6767 FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|426 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|427 /System/Applications/Safari.app/Contents/MacOS/Safari FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|428 Grok Bot FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|429 /Applications/Codex.app/Contents/MacOS/Codex FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|430 /usr/bin/python3 /opt/serve/runtime/bin/omnigent codex FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|431 python -P -m omnigent.cli server FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|432 python -P -m omnigent.host._daemon_entry FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|433 python -P -m omnigent.runner._zygote FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|434 python3.12 -I -W ignore -X dev -m omnigent FM_TASK_INBOX=$INBOX"
  "unclear|protected-app|435 python3 -- /opt/serve/bin/omnigent FM_TASK_INBOX=$INBOX"
  "own|task-env|436 python3 helper.py /opt/bin/omnigent FM_TASK_INBOX=$INBOX"
  "own|task-env|437 python3 -P -m helper omnigent.cli FM_TASK_INBOX=$INBOX"
  "own|task-env|438 python3 -c omnigent FM_TASK_INBOX=$INBOX"
  "own|task-env|439 python3 helper.py FM_OMNIGENT=on FM_TASK_INBOX=$INBOX"
  "own|task-env|440 python3 -W omnigent -X omnigent helper.py FM_TASK_INBOX=$INBOX"
  "own|task-env|441 python3 -m omnigently.cli FM_TASK_INBOX=$INBOX"

)

fm_task_proc_executable() {
  case "$1" in
    306) printf '%s\n' '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' ;;
    307) printf '%s\n' omnigent ;;
    408) printf '%s\n' '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' ;;
    409) printf '%s\n' '/Applications/Codex.app/Contents/SharedSupport/SkyComputerUseService' ;;
    420) printf '%s\n' hermes ;;
    421) printf '%s\n' mlflow ;;
    422) printf '%s\n' tailscale ;;
    423) printf '%s\n' '/System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing' ;;
    424) printf '%s\n' fm-remote-job-worker ;;
    425) printf '%s\n' server-6767 ;;
    426) printf '%s\n' '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser' ;;
    427) printf '%s\n' '/System/Applications/Safari.app/Contents/MacOS/Safari' ;;
    428) printf '%s\n' 'Grok Bot' ;;
    429) printf '%s\n' '/Applications/Codex.app/Contents/MacOS/Codex' ;;
    430|435|436|437|438|439|440|441) printf '%s\n' /usr/bin/python3 ;;
    431|432|433) printf '%s\n' /usr/bin/python ;;
    434) printf '%s\n' /usr/bin/python3.12 ;;
    *) printf '%s\n' node ;;
  esac
}

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
  assert_equals "$out" "101 102 103 405 406 407 436 437 438 439 440 441 " "own pids from a mixed listing"
  out=$(printf '%s\n' "$listing" | FM_TASK_PROC_EXCLUDE=$'101\n999' FM_TASK_PROC_INBOX=$INBOX \
    FM_TASK_PROC_ID=$ID FM_TASK_PROC_PROFILE=$PROFILE fm_task_proc_classify \
    | awk -F '\t' '$1 == "own" { print $2 }' | tr '\n' ' ')
  assert_equals "$out" "102 103 405 406 407 436 437 438 439 440 441 " "excluded (own or ancestor) pids are never classified"
  pass "a mixed listing yields exactly the task's own pids and honors exclusions"
}

test_requires_inbox() {
  if printf '101 node FM_TASK_INBOX=\n' | FM_TASK_PROC_INBOX='' fm_task_proc_classify >/dev/null; then
    fail "classifier must refuse without the task inbox identity"
  fi
  pass "classifier refuses to run without the task's inbox identity"
}

test_browser_identity() {
  local first second session home brief out prefix
  first=$(fm_task_proc_browser_session /Users/cap/home-a "$ID")
  second=$(fm_task_proc_browser_session /Users/cap/home-b "$ID")
  [ "$first" != "$second" ] || fail "equal task IDs in different homes share a browser"
  [ "$first" = "$(fm_task_proc_browser_session /Users/cap/home-a "$ID")" ] || fail "browser identity is unstable"
  out=$(printf '412 chrome --user-data-dir=/tmp/%s/browser-profile\n413 chrome --user-data-dir=/tmp/%s/browser-profile\n' "$first" "$second" | FM_TASK_PROC_INBOX=$INBOX FM_TASK_PROC_PROFILE="/tmp/$first/browser-profile" fm_task_proc_classify)
  assert_equals "$(printf '%s\n' "$out" | cut -f2)" 412 "only the browser for this home is selected"
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$ID" some-project --mode local-only >/dev/null
  session=$(fm_task_proc_browser_session "$home" "$ID")
  brief="$home/data/$ID/brief.md"
  assert_grep "CHROME_DEVTOOLS_AXI_SESSION=$session CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/tmp/$session/browser-profile" "$brief" "emitted browser launch contract agrees with cleanup identity"
  prefix=$(python3 - "$brief" <<'PYCODE'
import pathlib
import sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("   For browser work,"):
        print(line.split(chr(96))[1])
        break
else:
    raise SystemExit("missing emitted browser launch contract")
PYCODE
  )
  out=$(CHROME_DEVTOOLS_AXI_BROWSER_URL=http://captain.invalid:9222 CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 bash -c "$prefix env")
  assert_contains "$out" "CHROME_DEVTOOLS_AXI_SESSION=$session" "browser prefix sets the job session"
  assert_contains "$out" "CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/tmp/$session/browser-profile" "browser prefix sets the job profile"
  if printf '%s\n' "$out" | grep -Eq '^CHROME_DEVTOOLS_AXI_(BROWSER_URL|AUTO_CONNECT)='; then
    fail "browser prefix retained an inherited connection override"
  fi
  pass "browser identities match emitted briefs and clear inherited connection overrides"
}

# shellcheck disable=SC2329 # Overrides called by the sourced cleanup library.
test_close_revalidates() (
  local scenario signals expected
  fm_task_proc_ancestors() { printf '999\n'; }
  fm_task_proc_listing() {
    if [ ! -f "$TMP_ROOT/listed" ]; then
      : > "$TMP_ROOT/listed"
      printf '501 node helper FM_TASK_INBOX=%s\n' "$INBOX"
    elif [ "$scenario" = ownership-changed ]; then
      printf '501 node helper FM_TASK_INBOX=/other/home/state/job.inbox\n'
    else
      printf '501 node helper FM_TASK_INBOX=%s\n' "$INBOX"
    fi
  }
  task_process_identity() {
    [ "$scenario" != exited ] || return 1
    printf 'starttime=123\n'
  }
  task_process_identity_matches() {
    [ "$1" = 501 ] && [ "$2" = starttime=123 ] || fail "identity was not preserved"
    [ "$scenario" != pid-reused ]
  }
  kill() { printf '%s\n' "$*" >> "$TMP_ROOT/signals"; }
  for scenario in owned ownership-changed pid-reused exited; do
    rm -f "$TMP_ROOT/listed"
    : > "$TMP_ROOT/signals"
    FM_TASK_PROC_INBOX=$INBOX FM_TASK_PROC_ID=$ID FM_TASK_PROC_PROFILE=$PROFILE \
      FM_TASK_PROC_GRACE=0 fm_task_proc_close "$ID" 2> "$TMP_ROOT/report"
    signals=$(cat "$TMP_ROOT/signals")
    expected=''
    [ "$scenario" != owned ] || expected='-TERM 501'
    assert_equals "$signals" "$expected" "only a still-owned unchanged process is signalled ($scenario)"
  done
  pass "cleanup rechecks ownership and identity and skips exited or reused pids"
)

# shellcheck disable=SC2329 # Overrides called by the extracted retirement function.
test_retiring_child_cleanup() (
  local home child=retiring-worker session out
  home="$TMP_ROOT/retiring-home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'kind=ship\n' > "$home/state/$child.meta"
  session=$(fm_task_proc_browser_session "$home" "$child")
  awk '/^cleanup_firstmate_home_children\(\)/ { emitting=1 } emitting { print } emitting && /^}/ { exit }' \
    "$ROOT/bin/fm-teardown.sh" > "$TMP_ROOT/retire-function.sh"
  # shellcheck source=/dev/null
  . "$TMP_ROOT/retire-function.sh"
  meta_value() { sed -n "s/^$2=//p" "$1"; }
  fm_backend_of_meta() { printf 'tmux\n'; }
  fm_backend_target_of_meta() { :; }
  teardown_export_records() { :; }
  remove_grok_turnend_auth() { :; }
  remove_kimi_turnend_auth() { :; }
  remove_kiro_turnend_auth() { :; }
  remove_pr_poll_artifacts() { :; }
  retire_busy_state() { :; }
  teardown_retire_status() { :; }
  fm_wake_queue_prune_task() { :; }
  fm_wake_signal_seen_path() { printf '%s/unused\n' "$1"; }
  fm_backlog_atomic_transition() { rm "$2"; }
  fm_task_proc_ancestors() { printf '999\n'; }
  fm_task_proc_listing() {
    printf '601 node helper FM_TASK_INBOX=%s/state/%s.inbox\n' "$home" "$child"
    printf '602 chrome --user-data-dir=/tmp/%s/browser-profile\n' "$session"
    printf '603 node helper FM_TASK_INBOX=%s/state/%s.inbox\n' "$TMP_ROOT/other-home" "$child"
    printf '604 chrome --user-data-dir=/tmp/%s/browser-profile\n' "$(fm_task_proc_browser_session "$TMP_ROOT/other-home" "$child")"
  }
  task_process_identity() { printf 'starttime=123\n'; }
  task_process_identity_matches() { [ "$2" = starttime=123 ]; }
  kill() {
    [ -f "$home/state/$child.meta" ] || fail "child record was removed before process cleanup"
    printf '%s\n' "$*" >> "$TMP_ROOT/child-signals"
  }
  : > "$TMP_ROOT/child-signals"
  FM_TASK_PROC_GRACE=0 cleanup_firstmate_home_children "$home" parent 2> "$TMP_ROOT/child-report"
  out=$(cat "$TMP_ROOT/child-signals")
  assert_equals "$out" $'-TERM 601\n-TERM 602' "child retirement closes only its own helper and browser"
  assert_absent "$home/state/$child.meta" "child retirement did not remove the completed record"
  pass "child retirement closes owned processes before removing records"
)

# shellcheck disable=SC2329 # Overrides called by the sourced cleanup library.
test_python_omnigent_survives() (
  local signals
  fm_task_proc_ancestors() { printf '999\n'; }
  fm_task_proc_listing() {
    printf '%s\n' "${CASES[@]}" | cut -d'|' -f3- | awk '$1 >= 430 && $1 <= 435'
  }
  kill() { printf '%s\n' "$*" >> "$TMP_ROOT/python-signals"; }
  : > "$TMP_ROOT/python-signals"
  FM_TASK_PROC_INBOX=$INBOX FM_TASK_PROC_ID=$ID FM_TASK_PROC_PROFILE=$PROFILE \
    FM_TASK_PROC_GRACE=0 fm_task_proc_close "$ID" 2> "$TMP_ROOT/python-report"
  signals=$(cat "$TMP_ROOT/python-signals")
  assert_equals "$signals" '' "interpreted Omnigent processes must never receive signals"
  assert_contains "$(cat "$TMP_ROOT/python-report")" 'ownership unclear: protected-app' "protected Python processes remain visible for review"
  pass "cleanup leaves interpreted Omnigent programs running"
)

test_wrapped_worker_inbox() (
  . "$ROOT/tests/omnigent-fixture.sh"
  fm_test_omnigent_service "$TMP_ROOT/serve" "$TMP_ROOT/tools"
  HOME="$TMP_ROOT/brief-home" PATH="$TMP_ROOT/tools:$PATH" \
    FM_HOME="$TMP_ROOT/brief-home" FM_TASK_ID=$ID FM_TASK_INBOX=$INBOX \
    OMNI_RECORD_MODE=missing bash "$ROOT/bin/fm-omnigent.sh" run codex 'fixture prompt'
  jq -e --arg inbox "$INBOX" '.environment.FM_TASK_INBOX == $inbox' "$TMP_ROOT/serve/result.json" >/dev/null \
    || fail "wrapped worker lost the ownership inbox"
  pass "Omnigent launch forwards the worker ownership inbox"
)

TMP_ROOT=$(fm_test_tmproot fm-task-proc)
fm_test_run test_classifier_table test_mixed_listing_and_exclusion test_requires_inbox test_browser_identity test_close_revalidates test_retiring_child_cleanup test_python_omnigent_survives test_wrapped_worker_inbox
