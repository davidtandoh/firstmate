#!/usr/bin/env bash
# tests/fm-ask.test.sh - structured captain-ask records.
#
# Covers the schema 1 record a notifier reads (fields, file name, mode 600),
# stable ask ids and idempotent re-recording, caller keys, plain-text and
# credential validation, closing by id and by task, and the rule that a closed
# ask is never reopened.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ask)
ASK_BIN="$ROOT/bin/fm-ask.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_ask() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ASK_BIN" "$@"
}

field() {  # <file> <python-expression over r>
  python3 -c 'import json,sys
r=json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$1" "$2"
}

refused() {  # <home> <label> <args...>: open must exit 1 and write nothing new
  local home=$1 label=$2 before after code=0
  shift 2
  before=$(find "$home/state" -name '*.json' | wc -l | tr -d ' ')
  run_ask "$home" open "$@" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "$label"
  after=$(find "$home/state" -name '*.json' | wc -l | tr -d ' ')
  assert_equals "$before" "$after" "$label must not write a record"
}

test_open_writes_schema_record() {
  local home out file
  home=$(make_home schema)
  out=$(run_ask "$home" open --task GB-hook-1031 --kind decision \
    --question "Which relay shape ships first?" \
    --option "A=Ship the webhook now" --option "B=Wait for the queue" \
    --recommend A --reason "It unblocks alerts today." \
    --link https://github.com/example/repo/pull/7)
  assert_equals "opened: gb-hook-1031-decision-1" "$out" "open names the new ask id"
  file="$home/state/captain-asks/gb-hook-1031-decision-1.json"
  assert_present "$file" "the record is one file named by ask id"
  assert_equals 600 "$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file")" "record mode is 600"
  assert_equals "1|gb-hook-1031-decision-1|GB-hook-1031|decision|open" \
    "$(field "$file" '"|".join(str(r[k]) for k in ("schema","ask_id","task_id","kind","state"))')" \
    "core fields"
  assert_equals "[{'label': 'A', 'text': 'Ship the webhook now'}, {'label': 'B', 'text': 'Wait for the queue'}]" \
    "$(field "$file" 'r["options"]')" "options keep order"
  assert_equals "{'label': 'A', 'reason': 'It unblocks alerts today.'}" \
    "$(field "$file" 'r["recommendation"]')" "recommendation"
  assert_equals "['https://github.com/example/repo/pull/7']" "$(field "$file" 'r["links"]')" "links"
  field "$file" 'r["asked_at"]' | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "asked_at is RFC 3339 UTC"
  assert_equals "False" "$(field "$file" '"closed_at" in r')" "an open ask has no closed_at"
  assert_equals "" "$(find "$home/state/captain-asks" -name '*.tmp')" "no temp file is left behind"
  pass "open writes one schema 1 record per ask with mode 600"
}

test_plain_approval_has_empty_options_and_null_recommendation() {
  local home file
  home=$(make_home approval)
  run_ask "$home" open --task t1 --kind approval --question "Merge the fix?" >/dev/null
  file="$home/state/captain-asks/t1-approval-1.json"
  assert_equals "[]|None|[]" "$(field "$file" '"|".join(str(x) for x in (r["options"], r["recommendation"], r["links"]))')" \
    "a plain approval has empty options and links and a null recommendation"
  pass "a plain approval needs no options"
}

test_reopen_is_idempotent_and_new_asks_number_up() {
  local home first again second
  home=$(make_home idem)
  first=$(run_ask "$home" open --task t1 --kind decision --question "Pick A or B?" --option A=a --option B=b)
  again=$(run_ask "$home" open --task t1 --kind decision --question "Pick A or B?" --option A=a --option B=b)
  assert_equals "opened: t1-decision-1" "$first" "first open"
  assert_equals "unchanged: t1-decision-1" "$again" "a re-recorded ask keeps its ask id"
  second=$(run_ask "$home" open --task t1 --kind decision --question "Pick C or D?" --option C=c --option D=d)
  assert_equals "opened: t1-decision-2" "$second" "a different ask gets the next number"
  assert_equals 2 "$(find "$home/state/captain-asks" -name '*.json' | wc -l | tr -d ' ')" "two records, not three"
  pass "re-recording the same ask is idempotent and keeps ask_id"
}

test_caller_key_is_stable_and_refuses_drift() {
  local home out code=0
  home=$(make_home key)
  out=$(run_ask "$home" open --task t1 --kind blocker --question "Credentials expired on CI." --key ci-login)
  assert_equals "opened: ci-login" "$out" "the caller key is the ask id"
  out=$(run_ask "$home" open --task t1 --kind blocker --question "Credentials expired on CI." --key ci-login)
  assert_equals "unchanged: ci-login" "$out" "same key and content is a no-op"
  run_ask "$home" open --task t1 --kind blocker --question "Something else." --key ci-login >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "same key with different content is refused"
  code=0
  run_ask "$home" open --task t1 --kind blocker --question "Bad key." --key "CI Login" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a key that is not a lowercase slug is refused"
  pass "a caller key is a stable ask id and refuses changed content"
}

test_validation_refuses_markdown_secrets_and_bad_values() {
  local home long
  home=$(make_home validate)
  refused "$home" "bold markdown" --task t1 --kind decision --question "Ship **now**?"
  refused "$home" "code markdown" --task t1 --kind decision --question 'Run `make` first?'
  refused "$home" "link markdown" --task t1 --kind decision --question "See [PR](https://x.test)?"
  refused "$home" "heading markdown" --task t1 --kind decision --question "# Decide"
  refused "$home" "list markdown in an option" --task t1 --kind decision --question "Pick?" --option "A=- first"
  refused "$home" "a line break" --task t1 --kind decision --question $'Pick?\nNow.'
  refused "$home" "an empty question" --task t1 --kind decision --question ""
  long=$(printf 'x%.0s' $(seq 1 301))
  refused "$home" "a question over 300 characters" --task t1 --kind decision --question "$long"
  run_ask "$home" open --task t1 --kind decision --question "${long:1}" >/dev/null \
    || fail "a question of exactly 300 characters is accepted"
  refused "$home" "option text over 160 characters" --task t1 --kind decision --question "Pick?" \
    --option "A=$(printf 'y%.0s' $(seq 1 161))"
  refused "$home" "an unknown kind" --task t1 --kind question --question "Pick?"
  refused "$home" "an http link" --task t1 --kind approval --question "Merge?" --link http://example.com/pr/1
  refused "$home" "a link with no host" --task t1 --kind approval --question "Merge?" --link https:///pr
  refused "$home" "a duplicate option label" --task t1 --kind decision --question "Pick?" --option A=a --option A=b
  refused "$home" "a recommendation naming no option" --task t1 --kind decision --question "Pick?" \
    --option A=a --recommend B --reason "B is better."
  refused "$home" "a password" --task t1 --kind blocker --question "The password is hunter2."
  refused "$home" "a token in a link" --task t1 --kind approval --question "Merge?" \
    --link "https://example.com/pr/1?token=abc"
  refused "$home" "an api key in an option" --task t1 --kind decision --question "Pick?" --option "A=Use the API key"
  refused "$home" "an authorization header" --task t1 --kind blocker --question "Authorization: Bearer x"
  refused "$home" "a private key" --task t1 --kind blocker --question "Upload the private key?"
  pass "plain-text, length, link and credential rules refuse bad asks without writing"
}

test_usage_errors_exit_2() {
  local home code=0
  home=$(make_home usage)
  run_ask "$home" open --kind decision --question "Pick?" >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "open without --task"
  code=0
  run_ask "$home" bogus >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "unknown subcommand"
  code=0
  run_ask "$home" close t1-decision-1 >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "close without an outcome"
  run_ask "$home" --help | grep -q 'fm-ask.sh open' || fail "help prints usage"
  pass "usage errors exit 2"
}

test_close_by_id_and_task_and_never_reopen() {
  local home out code=0 file
  home=$(make_home close)
  run_ask "$home" open --task t1 --kind decision --question "First?" >/dev/null
  run_ask "$home" open --task t1 --kind approval --question "Second?" >/dev/null
  run_ask "$home" open --task t2 --kind blocker --question "Third." >/dev/null
  out=$(run_ask "$home" close t1-decision-1 --withdrawn)
  assert_equals "withdrawn: t1-decision-1" "$out" "close by id"
  file="$home/state/captain-asks/t1-decision-1.json"
  assert_equals "withdrawn|True" "$(field "$file" 'r["state"] + "|" + str("closed_at" in r)')" "a closed ask records closed_at"
  assert_equals 600 "$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file")" "a rewritten record stays mode 600"
  out=$(run_ask "$home" close t1-decision-1 --withdrawn)
  assert_equals "withdrawn: t1-decision-1" "$out" "closing again with the same outcome is a no-op"
  run_ask "$home" close t1-decision-1 --answered >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a different outcome on a closed ask is refused"
  out=$(run_ask "$home" close --task t1 --answered)
  assert_equals "answered: t1-approval-1" "$out" "close --task closes only that task's open asks"
  assert_equals "t2-blocker-1	open	t2	blocker	Third." "$(run_ask "$home" list --open)" "list --open keeps other tasks' asks"
  assert_equals 3 "$(run_ask "$home" list | wc -l | tr -d ' ')" "list shows every ask"
  code=0
  run_ask "$home" open --task t1 --kind approval --question "Second?" >/dev/null 2>&1 || code=$?
  expect_code 3 "$code" "re-recording a closed ask is refused with exit 3"
  assert_equals "" "$(run_ask "$home" list --open | grep t1 || true)" "the closed ask stays closed"
  code=0
  run_ask "$home" close no-such-ask --answered >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "closing an unknown ask fails"
  pass "asks close by id or task and a closed ask is never reopened"
}

test_corrupt_record_stops_reads() {
  local home code=0 err
  home=$(make_home corrupt)
  run_ask "$home" open --task t1 --kind decision --question "First?" >/dev/null
  printf '{not json' > "$home/state/captain-asks/broken.json"
  err=$(run_ask "$home" list 2>&1 >/dev/null) || code=$?
  expect_code 1 "$code" "a corrupt record stops list"
  assert_contains "$err" "broken.json" "the failure names the corrupt record"
  pass "a corrupt record is reported, not skipped"
}

fm_test_run \
  test_open_writes_schema_record \
  test_plain_approval_has_empty_options_and_null_recommendation \
  test_reopen_is_idempotent_and_new_asks_number_up \
  test_caller_key_is_stable_and_refuses_drift \
  test_validation_refuses_markdown_secrets_and_bad_values \
  test_usage_errors_exit_2 \
  test_close_by_id_and_task_and_never_reopen \
  test_corrupt_record_stops_reads
