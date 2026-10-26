#!/usr/bin/env bash
# Status-stage timing and a shared bounded preflight, without a live service.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/omnigent-fixture.sh"
TMP_ROOT=$(fm_test_tmproot fm-omnigent-preflight)
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH" FM_TIMING_LOG="$TMP_ROOT/timing.tsv"
export FM_TEST_OMNIGENT_PREFLIGHT_BUDGET=3
# Delay exactly one service-owned stage without bypassing its returned identity.
for stage in status readiness; do
  : > "$FM_TIMING_LOG"
  OMNI_DELAY_STAGE=$stage OMNI_STAGE_DELAY=1 bash "$ROOT/bin/fm-omnigent.sh" check codex
  awk -F '\t' -v stage="$stage" '$2 == "omnigent-preflight" && $3 == stage && $5 >= 900 { found=1 } END { exit !found }' "$FM_TIMING_LOG" \
    || fail "preflight did not time the delayed $stage stage"
done
: > "$FM_TIMING_LOG"
if OMNI_DELAY_STAGE=status OMNI_STAGE_DELAY=10 bash "$ROOT/bin/fm-omnigent.sh" check codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'preflight accepted a status command beyond its total budget'
fi
grep -q 'stage=status.*timed out' "$TMP_ROOT/error" || fail 'timeout did not name the slow stage'
# Even fast output with contradictory process identity still refuses.
jq '.managed_status.status="stopped"' "$TMP_ROOT/service/readiness.json" > "$TMP_ROOT/bad.json"
mv "$TMP_ROOT/bad.json" "$TMP_ROOT/service/readiness.json"
if bash "$ROOT/bin/fm-omnigent.sh" check codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'timing weakened readiness process-identity validation'
fi
pass 'status and readiness stages are measured; the shared deadline and identity checks remain fail closed'
