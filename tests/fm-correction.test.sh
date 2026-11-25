#!/usr/bin/env bash
# tests/fm-correction.test.sh - the captain corrections log and its repeat rule.
#
# Covers the created log table, row validation, list and repeats output, the
# refusal to append into a foreign table, and the repeat rule: the second row
# in a class holds one `correct-<class>` task for the captain, and later rows
# leave that hold in place.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-correction)
BIN="$ROOT/bin/fm-correction.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

run_fc() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$BIN" "$@"
}

task_show() {  # <home> <id>: decoded view, as Firstmate reads it
  FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" "$ROOT/bin/fm-tasks-axi.sh" show "$2"
}

test_first_row_creates_log_without_hold() {
  local home out
  home=$(make_home first)
  out=$(run_fc "$home" add --class merge-around-guard --date 2026-10-29 \
    --description "Merged with raw gh pr merge instead of fm-pr-merge" \
    --evidence "guidex_meta PR 362")
  assert_equals "logged: merge-around-guard (1 in class)" "$out" "first row is logged alone"
  assert_grep '| Date | Class | Description | Evidence |' "$home/data/corrections.md"
  assert_grep '| 2026-10-29 | merge-around-guard | Merged with raw gh pr merge instead of fm-pr-merge | guidex_meta PR 362 |' \
    "$home/data/corrections.md"
  task_show "$home" correct-merge-around-guard >/dev/null 2>&1 \
    && fail "a single row must not file a correct task"
  pass "the first row creates the log table and files nothing"
}

test_repeat_holds_one_correct_task() {
  local home out show
  home=$(make_home repeat)
  run_fc "$home" add --class done-before-pr --date 2026-10-30 \
    --description "Worker reported done before opening its PR" --evidence "data/learnings.md:35" >/dev/null
  out=$(run_fc "$home" add --class done-before-pr --date 2026-11-25 \
    --description "Worker reported done before opening its PR" --evidence "https://example.com/pr/9")
  assert_contains "$out" "logged: done-before-pr (2 in class)" "second row counts the class"
  assert_contains "$out" "correct task held: correct-done-before-pr" "second row holds the task"
  show=$(task_show "$home" correct-done-before-pr)
  assert_contains "$show" "Correct repeated mistake: done-before-pr" "task title names the class"
  assert_contains "$show" "captain" "task is held for the captain"
  assert_contains "$show" "data/learnings.md:35" "hold reason carries the first evidence"
  assert_contains "$show" "https://example.com/pr/9" "hold reason carries the repeat evidence"
  out=$(run_fc "$home" add --class done-before-pr --date 2026-11-26 \
    --description "Worker reported done before opening its PR" --evidence "third")
  assert_contains "$out" "correct task already covers class: correct-done-before-pr" "a third row keeps the same hold"
  assert_equals 1 "$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" list | grep -c 'correct-done-before-pr')" \
    "repeats never file a second task"
  pass "the second row in a class holds one correct task and later rows keep it"
}

test_released_and_inflight_tasks_stay_unchanged() {
  local home out before
  home=$(make_home released)
  run_fc "$home" add --class released --description first --evidence e1 >/dev/null
  run_fc "$home" add --class released --description second --evidence e2 >/dev/null
  printf 'Implement the structural guard.\n' > "$home/decision.txt"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer correct-released \
    --decision-file "$home/decision.txt" --release >/dev/null
  before=$(task_show "$home" correct-released)
  out=$(run_fc "$home" add --class released --description third --evidence e3)
  assert_contains "$out" "correct task already covers class: correct-released" "released work covers the class"
  assert_equals "$before" "$(task_show "$home" correct-released)" "released task is untouched"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" start correct-released >/dev/null
  before=$(task_show "$home" correct-released)
  out=$(run_fc "$home" add --class released --description fourth --evidence e4)
  assert_contains "$out" "correct task already covers class: correct-released" "in-flight work covers the class"
  assert_equals "$before" "$(task_show "$home" correct-released)" "in-flight task is untouched"
  pass "recurrences preserve released and in-flight work"
}

test_closed_tasks_get_dated_successors() {
  local home out before successor
  home=$(make_home closed)
  run_fc "$home" add --class closed --description first --evidence e1 >/dev/null
  run_fc "$home" add --class closed --description second --evidence e2 >/dev/null
  printf 'The guard is complete.\n' > "$home/decision.txt"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer correct-closed \
    --decision-file "$home/decision.txt" >/dev/null
  before=$(task_show "$home" correct-closed)
  out=$(run_fc "$home" add --class closed --date 2026-11-25 --description third --evidence e3)
  successor=correct-closed-2026-11-25
  assert_contains "$out" "correct task held: $successor" "closed work gets a dated successor"
  assert_equals "$before" "$(task_show "$home" correct-closed)" "closed task is untouched"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" open "$successor" || fail "successor must be held"
  before=$(task_show "$home" "$successor")
  out=$(run_fc "$home" add --class closed --date 2026-11-26 --description fourth --evidence e4)
  assert_contains "$out" "correct task already covers class: $successor" "later dates reuse open successors"
  assert_equals "$before" "$(task_show "$home" "$successor")" "successor stays untouched"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer "$successor" \
    --decision-file "$home/decision.txt" >/dev/null
  out=$(run_fc "$home" add --class closed --date 2026-11-25 --description fifth --evidence e5)
  assert_contains "$out" "correct task held: $successor-2" "same-date collisions get a numeric suffix"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" open "$successor-2" || fail "numbered successor must be held"
  pass "closed work gets held dated successors without reopening completed tasks"
}

test_archived_tasks_keep_their_identities() {
  local home out successor
  home=$(make_home archived)
  mkdir -p "$home/data/history"
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/history/completed.md"
done_keep = 1
TOML
  run_fc "$home" add --class archived --description first --evidence e1 >/dev/null
  run_fc "$home" add --class archived --description second --evidence e2 >/dev/null
  printf 'The guard is complete.\n' > "$home/decision.txt"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer correct-archived \
    --decision-file "$home/decision.txt" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add archive-trigger-1 "Trigger retention" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "done" archive-trigger-1 >/dev/null
  assert_grep 'correct-archived' "$home/data/history/completed.md" "completion archives the original id"
  if task_show "$home" correct-archived >/dev/null 2>&1; then
    fail "the original task must be absent from the live backlog"
  fi
  out=$(run_fc "$home" add --class archived --date 2026-11-25 --description third --evidence e3)
  successor=correct-archived-2026-11-25
  assert_contains "$out" "correct task held: $successor" "archived work gets a dated successor"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" open "$successor" || fail "successor must be held"
  if task_show "$home" correct-archived >/dev/null 2>&1; then
    fail "recurrence must not recreate the archived original id"
  fi
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer "$successor" \
    --decision-file "$home/decision.txt" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add archive-trigger-2 "Trigger retention again" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "done" archive-trigger-2 >/dev/null
  assert_grep "$successor" "$home/data/history/completed.md" "completion archives the dated id"
  if task_show "$home" "$successor" >/dev/null 2>&1; then
    fail "the dated task must be absent from the live backlog"
  fi
  out=$(run_fc "$home" add --class archived --date 2026-11-25 --description fourth --evidence e4)
  assert_contains "$out" "correct task held: $successor-2" "archived dated collisions get a numeric suffix"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" open "$successor-2" || fail "numbered successor must be held"
  pass "archived correction identities stay reserved in the configured archive"
}

test_list_and_repeats() {
  local home
  home=$(make_home listing)
  run_fc "$home" add --class a-class --date 2026-11-01 --description "one" --evidence "e1" >/dev/null
  run_fc "$home" add --class b-class --date 2026-11-02 --description "two" --evidence "e2" >/dev/null
  run_fc "$home" add --class a-class --date 2026-11-03 --description "three" --evidence "e3" >/dev/null
  assert_equals "$(printf '2026-11-01\ta-class\tone\te1\n2026-11-03\ta-class\tthree\te3')" \
    "$(run_fc "$home" list --class a-class)" "list filters by class"
  assert_equals 3 "$(run_fc "$home" list | wc -l | tr -d ' ')" "list prints every row"
  assert_equals "$(printf 'a-class\t2')" "$(run_fc "$home" repeats)" "repeats names only repeated classes"
  pass "list and repeats read the logged rows"
}

test_validation_and_foreign_table() {
  local home code
  home=$(make_home invalid)
  for args in "--class Bad_Class --description d --evidence e" \
              "--class ok --description a|b --evidence e" \
              "--class ok --description d --evidence e --date 25-11-2026"; do
    code=0
    # shellcheck disable=SC2086
    run_fc "$home" add $args >/dev/null 2>&1 || code=$?
    expect_code 1 "$code" "refused: $args"
  done
  code=0
  run_fc "$home" add --class ok --description "$(printf 'two\nlines')" --evidence e >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a line break is refused"
  code=0
  run_fc "$home" add --class ok >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "missing fields are a usage error"
  assert_absent "$home/data/corrections.md" "refused rows write nothing"
  printf '# Old log\n\n| Date | Correction | Class | Landed |\n|---|---|---|---|\n' > "$home/data/corrections.md"
  code=0
  run_fc "$home" add --class ok --description d --evidence e >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a log without the table header is refused"
  assert_no_grep '| ok |' "$home/data/corrections.md"
  pass "invalid rows and a foreign table are refused without writing"
}

fm_test_run \
  test_first_row_creates_log_without_hold \
  test_repeat_holds_one_correct_task \
  test_released_and_inflight_tasks_stay_unchanged \
  test_closed_tasks_get_dated_successors \
  test_archived_tasks_keep_their_identities \
  test_list_and_repeats \
  test_validation_and_foreign_table
