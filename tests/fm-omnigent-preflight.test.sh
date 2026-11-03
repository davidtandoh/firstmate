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
runtime="$TMP_ROOT/service/runtime/bin/omnigent"
real_jq=$(type -P jq)
mkdir -p "$TMP_ROOT/binary64"
# Emulate the numeric transport of jq versions that use binary64 numbers.
python3 - "$runtime" "$TMP_ROOT/binary64/jq" "$real_jq" <<'PY'
import os
from pathlib import Path
import sys

runtime, shim, jq = sys.argv[1:]
stamp = 1700000000000123000
os.utime(runtime, ns=(stamp, stamp))
assert os.stat(runtime).st_mtime_ns == stamp
assert int(float(stamp)) != stamp
Path(shim).write_text('''#!/usr/bin/env python3
import json
import subprocess
import sys

result = subprocess.run([REAL_JQ] + sys.argv[1:], input=sys.stdin.buffer.read(),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
def binary64(value):
    if type(value) is int and abs(value) > 2**53:
        return int(float(value))
    if isinstance(value, list):
        return [binary64(item) for item in value]
    if isinstance(value, dict):
        return {key: binary64(item) for key, item in value.items()}
    return value
output = result.stdout
if result.returncode == 0:
    try:
        value = json.loads(output)
        rounded = binary64(value)
        if rounded != value:
            output = (json.dumps(rounded) + '\\n').encode()
    except (ValueError, UnicodeDecodeError):
        pass
sys.stdout.buffer.write(output)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
'''.replace('REAL_JQ', repr(jq)))
os.chmod(shim, 0o700)
PY
original_path=$PATH
export PATH="$TMP_ROOT/binary64:$PATH"
[ "$(printf '1700000000000123000\n' | jq .)" != 1700000000000123000 ] || fail 'binary64 transport fixture did not round the timestamp'
CLAUDE_CONFIG_DIR=/unrelated/supervisor-login bash "$ROOT/bin/fm-omnigent.sh" check codex
[ -f "$FM_OMNIGENT_PREFLIGHT" ] || fail 'spawn check did not publish a private preflight handoff'
python3 - "$runtime" "$FM_OMNIGENT_PREFLIGHT" <<'PY'
import json
import os
from pathlib import Path
import sys

info = os.stat(sys.argv[1])
identity = json.loads(Path(sys.argv[2]).read_text())['identity']
assert identity['inode'] == str(info.st_ino)
assert identity['mtime_ns'] == str(info.st_mtime_ns)
PY
jq -e 'has("created") | not' "$FM_OMNIGENT_PREFLIGHT" >/dev/null || fail 'handoff still carries a launch timestamp'
: > "$TMP_ROOT/service/agent-kit.log"
: > "$TMP_ROOT/service/runtime/bin/help.log"
CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex > "$TMP_ROOT/preview"
export PATH="$original_path"
[ ! -e "$FM_OMNIGENT_PREFLIGHT" ] || fail 'pane did not consume the preflight handoff'
[ ! -s "$TMP_ROOT/service/agent-kit.log" ] || fail 'pane repeated status or readiness'
[ ! -s "$TMP_ROOT/service/runtime/bin/help.log" ] || fail 'pane repeated capability probing'
pass 'spawn check preserves exact identity through binary64 transport and the pane reuses its result'
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
rm -f "$HOME/state/.omnigent-capabilities-codex.json"
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
: > "$TMP_ROOT/service/runtime/bin/help.log"
runtime="$TMP_ROOT/service/runtime/bin/omnigent"
python3 - "$runtime" <<'PY'
import os, sys
path = sys.argv[1]
os.utime(path, ns=(os.stat(path).st_atime_ns, 1700000000123000001))
mtime = os.stat(path).st_mtime_ns
assert mtime != int(float(mtime)), 'fixture timestamp must lose precision in binary64'
PY
bash "$ROOT/bin/fm-omnigent.sh" check codex
python3 - "$runtime" "$HOME/state/.omnigent-capabilities-codex.json" <<'PY'
import json, os, sys
from pathlib import Path
info = os.stat(sys.argv[1])
with open(sys.argv[2]) as source:
    record = json.load(source)
assert record['key'] == [str(Path(sys.argv[1]).resolve()), str(info.st_ino), str(info.st_mtime_ns)]
PY
bash "$ROOT/bin/fm-omnigent.sh" check codex
[ "$(wc -l < "$TMP_ROOT/service/runtime/bin/help.log" | tr -d ' ')" = 1 ] || fail 'unchanged runtime repeated its capability probe'
pass 'unchanged runtime capabilities are probed once per harness'
: > "$TMP_ROOT/service/agent-kit.log"
bash "$ROOT/bin/fm-omnigent.sh" check codex
[ "$(wc -l < "$TMP_ROOT/service/agent-kit.log" | tr -d ' ')" = 2 ] || fail 'capability cache skipped status or readiness'
if OMNI_HEALTH=down bash "$ROOT/bin/fm-omnigent.sh" check codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'capability cache skipped health verification'
fi
grep -q 'server is unreachable' "$TMP_ROOT/error" || fail 'cached health refusal was not actionable'
bash "$ROOT/bin/fm-omnigent.sh" check claude
[ "$(wc -l < "$TMP_ROOT/service/runtime/bin/help.log" | tr -d ' ')" = 2 ] || fail 'capability cache crossed harnesses'
for change in inode mtime path malformed numeric; do
  case "$change" in
    inode) cp -p "$runtime" "$runtime.new"; mv "$runtime.new" "$runtime" ;;
    mtime)
      python3 - "$runtime" <<'PY'
import os, sys
path = sys.argv[1]
before = os.stat(path)
fraction = 123000000 if before.st_mtime_ns % 1000000000 != 123000000 else 124000000
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns // 1000000000 * 1000000000 + fraction))
after = os.stat(path)
assert after.st_mtime_ns // 1000000000 == before.st_mtime_ns // 1000000000
assert after.st_mtime_ns != before.st_mtime_ns
PY
      ;;
    path)
      next="$TMP_ROOT/service/generations/next/runtime/bin/omnigent"
      mkdir -p "${next%/*}"
      ln "$runtime" "$next"
      jq --arg executable "$next" '.runtime.executable=$executable' "$TMP_ROOT/service/readiness.json" > "$TMP_ROOT/changed"
      mv "$TMP_ROOT/changed" "$TMP_ROOT/service/readiness.json"
      runtime=$next ;;
    malformed) printf '{invalid\n' > "$HOME/state/.omnigent-capabilities-codex.json" ;;
    numeric)
      python3 - "$HOME/state/.omnigent-capabilities-codex.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as source:
    record = json.load(source)
record['key'][1:] = [int(value) for value in record['key'][1:]]
with open(path, 'w') as output:
    json.dump(record, output)
PY
      ;;
  esac
  : > "${runtime%/*}/help.log"
  bash "$ROOT/bin/fm-omnigent.sh" check codex
  bash "$ROOT/bin/fm-omnigent.sh" check codex
  [ "$(wc -l < "${runtime%/*}/help.log" | tr -d ' ')" = 1 ] || fail "$change did not trigger exactly one new probe"
done
pass 'capability cache invalidates on inode, subsecond mtime and real-path changes while other preflight remains fresh'
preview_state="$TMP_ROOT/preview-state"
FM_STATE_OVERRIDE="$preview_state" bash "$ROOT/bin/fm-omnigent.sh" run --dry-run codex > "$TMP_ROOT/preview"
[ ! -e "$preview_state" ] || fail 'dry run wrote a capability cache'
cache="$HOME/state/.omnigent-capabilities-codex.json"
cp "$cache" "$TMP_ROOT/protected-cache"
cp "$cache" "$TMP_ROOT/expected-cache"
rm "$cache"
ln -s "$TMP_ROOT/protected-cache" "$cache"
if bash "$ROOT/bin/fm-omnigent.sh" check codex > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'symlink capability cache accepted'
fi
cmp -s "$TMP_ROOT/expected-cache" "$TMP_ROOT/protected-cache" || fail 'cache writer changed the symlink target'
rm "$cache"
pass 'dry run preserves state and unsafe cache files refuse without modifying their targets'
fm_test_omnigent_service "$TMP_ROOT/service" "$TMP_ROOT/tools"
if OMNI_HELP='no native environment interface' bash "$ROOT/bin/fm-omnigent.sh" check kiro > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'unsupported environment interface was cached as supported'
fi
[ ! -e "$HOME/state/.omnigent-capabilities-kiro.json" ] || fail 'unsupported capability was persisted'
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
# The deadline case needs a new runtime identity rather than a cache hit.
touch -t 202201010000 "$TMP_ROOT/service/runtime/bin/omnigent"
if OMNI_DELAY_STAGE=capability OMNI_STAGE_DELAY=10 bash "$ROOT/bin/fm-omnigent.sh" check claude > "$TMP_ROOT/out" 2> "$TMP_ROOT/error"; then
  fail 'preflight accepted a capability command beyond its total budget'
fi
grep -q 'stage=capability.*timed out' "$TMP_ROOT/error" || fail 'timeout did not name the capability stage'
pass 'capability remains bounded by the shared deadline'
