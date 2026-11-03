#!/usr/bin/env bash
# Generation-bound handoffs and bounded preflight stages.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/tests/omnigent-fixture.sh"
TMP_ROOT=$(fm_test_tmproot fm-omnigent-preflight)
export HOME="$TMP_ROOT/home" FM_HOME="$TMP_ROOT/home"
unset FM_STATE_OVERRIDE FM_OMNIGENT_PREFLIGHT FM_OMNIGENT_RECORD_GEN FM_OMNIGENT_RECORD_META
mkdir -p "$HOME/state"
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
export PATH="$TMP_ROOT/tools:$PATH" FM_TIMING_LOG="$TMP_ROOT/timing.tsv"
export FM_OMNIGENT_RECORD_GEN=s.preflight.1 FM_OMNIGENT_RECORD_META="$HOME/state/worker.meta"
export FM_OMNIGENT_PREFLIGHT="$HOME/state/.worker.omnigent-preflight.s.preflight.1.json"
printf 'spawn_gen=%s\n' "$FM_OMNIGENT_RECORD_GEN" > "$FM_OMNIGENT_RECORD_META"
CLAUDE_CONFIG_DIR=/unrelated/supervisor-login bash "$ROOT/bin/fm-omnigent.sh" check codex
[ -f "$FM_OMNIGENT_PREFLIGHT" ] || fail 'spawn check did not publish a private preflight handoff'
jq -e 'has("created") | not' "$FM_OMNIGENT_PREFLIGHT" >/dev/null || fail 'handoff still carries a launch timestamp'
: > "$TMP_ROOT/service/agent-kit.log"
: > "$TMP_ROOT/service/runtime/bin/help.log"
CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex > "$TMP_ROOT/preview"
[ ! -e "$FM_OMNIGENT_PREFLIGHT" ] || fail 'pane did not consume the preflight handoff'
[ ! -s "$TMP_ROOT/service/agent-kit.log" ] || fail 'pane repeated status or readiness'
[ ! -s "$TMP_ROOT/service/runtime/bin/help.log" ] || fail 'pane repeated capability probing'
pass 'spawn check hands one verified result to the pane without repeating expensive stages'
handoff() {
  rm -f "$FM_OMNIGENT_PREFLIGHT"
  printf 'spawn_gen=%s\n' "$FM_OMNIGENT_RECORD_GEN" > "$FM_OMNIGENT_RECORD_META"
  bash "$ROOT/bin/fm-omnigent.sh" check codex
}
refuse_handoff() {
  if bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
    fail "invalid handoff accepted: $1"
  fi
  grep -q 'invalid preflight handoff' "$TMP_ROOT/error" || fail "handoff refusal missing: $1"
}
# A consumed handoff cannot be reused, even by the same generation.
refuse_handoff replay
handoff
if OMNI_HEALTH=down bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'pane skipped health verification'
fi
grep -q 'server is unreachable' "$TMP_ROOT/error" || fail 'pane skipped health verification'
for invalid in generation retired harness selector corrupt permissions symlink oversized; do
  handoff
  case "$invalid" in
    generation) printf 'spawn_gen=s.newer\n' > "$FM_OMNIGENT_RECORD_META" ;;
    retired) printf 'omnigent_retired_gen=%s\n' "$FM_OMNIGENT_RECORD_GEN" >> "$FM_OMNIGENT_RECORD_META" ;;
    harness|selector)
      case "$invalid" in
        harness) filter='.harness="claude"' ;;
        selector) filter='.selector="/different/login"' ;;
      esac
      jq "$filter" "$FM_OMNIGENT_PREFLIGHT" > "$TMP_ROOT/changed"
      cat "$TMP_ROOT/changed" > "$FM_OMNIGENT_PREFLIGHT" ;;
    corrupt) printf '[]\n' > "$FM_OMNIGENT_PREFLIGHT" ;;
    permissions) chmod 644 "$FM_OMNIGENT_PREFLIGHT" ;;
    symlink)
      mv "$FM_OMNIGENT_PREFLIGHT" "$TMP_ROOT/saved"
      ln -s "$TMP_ROOT/saved" "$FM_OMNIGENT_PREFLIGHT" ;;
    oversized) head -c 131073 /dev/zero > "$FM_OMNIGENT_PREFLIGHT" ;;
  esac
  refuse_handoff "$invalid"
done
runtime="$TMP_ROOT/service/runtime/bin/omnigent"
for change in inode mtime missing symlink; do
  handoff
  cp -p "$runtime" "$TMP_ROOT/original"
  case "$change" in
    inode) cp -p "$runtime" "$runtime.new"; mv "$runtime.new" "$runtime" ;;
    mtime) touch -t 202001010000 "$runtime" ;;
    missing) rm "$runtime" ;;
    symlink) rm "$runtime"; ln -s "$TMP_ROOT/original" "$runtime" ;;
  esac
  refuse_handoff "$change"
  rm -f "$runtime"
  cp -p "$TMP_ROOT/original" "$runtime"
done
pass 'handoff rejects replay, stale generation, retirement, wrong context and executable changes'
handoff
: > "$TMP_ROOT/service/agent-kit.log"
bash "$ROOT/bin/fm-omnigent.sh" start --dry-run codex >/dev/null
[ "$(wc -l < "$TMP_ROOT/service/agent-kit.log" | tr -d ' ')" = 2 ] || fail 'start reused a worker handoff'
[ -f "$FM_OMNIGENT_PREFLIGHT" ] || fail 'start consumed a worker handoff'
rm -f "$FM_OMNIGENT_PREFLIGHT"
unset FM_OMNIGENT_RECORD_GEN FM_OMNIGENT_RECORD_META FM_OMNIGENT_PREFLIGHT
: > "$TMP_ROOT/service/runtime/bin/help.log"
bash "$ROOT/bin/fm-omnigent.sh" check codex
bash "$ROOT/bin/fm-omnigent.sh" check codex
bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex >/dev/null
bash "$ROOT/bin/fm-omnigent.sh" start --dry-run codex >/dev/null
[ "$(wc -l < "$TMP_ROOT/service/runtime/bin/help.log" | tr -d ' ')" = 4 ] || fail 'full preflight skipped a capability probe'
[ "$(find "$HOME/state" -name '.omnigent-capabilities-*' | wc -l | tr -d ' ')" = 0 ] || fail 'full preflight persisted a capability cache'
pass 'check, unbound run and start always probe capabilities without a persistent cache'
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
if OMNI_HELP='no environment option' bash "$ROOT/bin/fm-omnigent.sh" check kiro > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'unsupported environment interface was accepted'
fi
grep -q 'lacks the native --env interface' "$TMP_ROOT/error" || fail 'unsupported environment refusal missing'
bash "$ROOT/bin/fm-omnigent.sh" check kiro
export FM_TEST_OMNIGENT_PREFLIGHT_BUDGET=8
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
# Readiness has no fixed stage limit: a slow report inside the shared budget
# passes even when it outlasts the former 15-second readiness cap.
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
export FM_TEST_OMNIGENT_PREFLIGHT_BUDGET=50
: > "$FM_TIMING_LOG"
OMNI_DELAY_STAGE=readiness OMNI_STAGE_DELAY=16 bash "$ROOT/bin/fm-omnigent.sh" check codex 2> "$TMP_ROOT/error" \
  || fail "slow readiness inside the shared budget refused: $(cat "$TMP_ROOT/error")"
pass 'readiness uses the remaining shared budget instead of a fixed stage limit'
# Capability probing shares the deadline too, including on a busy host.
: > "$FM_TIMING_LOG"
OMNI_DELAY_STAGE=capability OMNI_STAGE_DELAY=11 bash "$ROOT/bin/fm-omnigent.sh" check claude 2> "$TMP_ROOT/error" \
  || fail "slow capability inside the shared budget refused: $(cat "$TMP_ROOT/error")"
pass 'capability uses the remaining shared budget instead of a fixed stage limit'
export FM_TEST_OMNIGENT_PREFLIGHT_BUDGET=8
if OMNI_DELAY_STAGE=capability OMNI_STAGE_DELAY=10 bash "$ROOT/bin/fm-omnigent.sh" check claude > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'preflight accepted a capability command beyond its total budget'
fi
grep -q 'stage=capability.*timed out' "$TMP_ROOT/error" || fail 'timeout did not name the capability stage'
pass 'capability remains bounded by the shared deadline'
