#!/usr/bin/env bash
# Omnigent launch boundary. The underlying harness remains dispatch/control identity.
# Usage: fm-omnigent.sh mode <config-dir>
#        fm-omnigent.sh check <claude|codex|kiro|agy>
#        fm-omnigent.sh run [--dry-run] <harness> <Firstmate native arguments...>
#        fm-omnigent.sh start [--dry-run] <claude|codex>
# mode: config/omnigent (auto|on, absent=auto) can force wrapping; otherwise
# OMNIGENT=1 enables wrapping before inherited FM_OMNIGENT (on|off).
# Invalid input refuses.
# check/run/start resolve the local Kit's serve status afresh. The client is
# readiness runtime.executable, never a cached generation or PATH install.
# run accepts the exact native argv fm-spawn builds: Claude/Codex/Kiro end in
# the initial prompt; Kiro starts with chat; AGY carries --prompt-interactive.
# Only the four native wrappers with a verified --env contract are admitted.
# The explicit environment below carries Firstmate-owned launch settings,
# not a copy of the supervisor's environment. Empty foreign markers prevent
# a long-lived runner from restoring an unrelated primary identity.
# The Kit owns capture/export policy. Firstmate neither configures nor starts
# the server. A failed preflight or launch never falls back to the native CLI.
# --dry-run prints the resolved executable and service paths without launch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"

fail() { printf 'error: Omnigent launch: %s\n' "$*" >&2; exit 1; }
mode() {
  local file=$1/omnigent value=auto inherited=${FM_OMNIGENT:-}
  case "$inherited" in ''|on|off) ;; *) fail 'FM_OMNIGENT must be on or off' ;; esac
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ ! -L "$file" ] && [ -f "$file" ] && [ -r "$file" ] || fail "expected regular policy file: $file"
    value=$(head -c 65 "$file") || fail "cannot read $file"
    [ "${#value}" -le 64 ] || fail "oversized policy file: $file"
  fi
  case "$value" in
    on) echo on ;;
    auto) if [ "${OMNIGENT:-}" = 1 ]; then echo on; elif [ -n "$inherited" ]; then printf '%s\n' "$inherited"; else echo off; fi ;;
    *) fail "expected auto or on in $file" ;;
  esac
}

resolve_service() {
  local status readiness reason help health candidate service_root status_rc=0 readiness_rc=0
  case "$HARNESS" in claude|codex|kiro|agy) ;; *) fail "unverified wrapped harness: $HARNESS" ;; esac
  command -v agent-kit >/dev/null 2>&1 || fail 'agent-kit is required on this host'
  command -v jq >/dev/null 2>&1 || fail 'jq is required on this host'
  command -v curl >/dev/null 2>&1 || fail 'curl is required on this host'
  status=$(fm_run_timed 15 agent-kit observe serve status --json < /dev/null | head -c 131073) || status_rc=$?
  fm_timed_out "$status_rc" && fail 'agent-kit observe serve status --json timed out'
  [ "${#status}" -le 131072 ] || fail 'serve status exceeds 128 KiB'
  printf '%s' "$status" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || fail 'invalid serve status JSON'
  if ! printf '%s' "$status" | jq -e '.status == "running"' >/dev/null; then
    reason=$(printf '%s' "$status" | jq -r '.reason // .status // "missing status"')
    fail "agent-kit observe serve is unavailable: $reason"
  fi
  [ "$status_rc" = 0 ] || fail "agent-kit status failed with exit $status_rc"
  printf '%s' "$status" | jq -e '
    (.state_file | type == "string" and startswith("/") and (test("[\u0000-\u001f\u007f]") | not)) and
    (.server_url | type == "string" and test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+/?$")) and
    (.client_environment | type == "object" and length > 0 and
      all(to_entries[]; (.key | test("^(OMNIGENT_|OTEL_)[A-Z0-9_]+$")) and
        (.value | type == "string" and (test("[\u0000-\u001f\u007f]") | not))))
  ' >/dev/null 2>&1 || fail 'serve status lacks a valid local server, state path, or client environment'
  SERVER=$(printf '%s' "$status" | jq -r .server_url)
  STATE_FILE=$(printf '%s' "$status" | jq -r .state_file)
  readiness=$(fm_run_timed 15 agent-kit observe serve status --readiness --json < /dev/null | head -c 131073) || readiness_rc=$?
  fm_timed_out "$readiness_rc" && fail 'serve readiness timed out'
  [ "${#readiness}" -le 131072 ] || fail 'serve readiness exceeds 128 KiB'
  # Headless rollback remains usable even though the web-readiness gate is not
  # ready. All other readiness failures refuse before probing any executable.
  printf '%s' "$readiness" | jq -se --arg server "$SERVER" --arg rc "$readiness_rc" '
    length == 1 and (.[0] |
      .schema_version == "1" and
      (.reasons | type == "array") and
      ((.status == "ready" and .reasons == [] and $rc == "0") or
       (.status == "unavailable" and $rc == "0" and (.reasons | length > 0) and
        all(.reasons[]; . == "serve_setup_headless_only" or . == "serve_web_assets_missing"))) and
      .managed_status.status == "running" and .managed_service.server_url == $server and
      (.runtime.executable | type == "string" and startswith("/") and
        (test("[\u0000-\u001f\u007f]") | not) and
        (split("/")[1:] | all(. != "" and . != "." and . != ".."))))
  ' >/dev/null 2>&1 || fail 'invalid or inconsistent serve readiness'
  OMNIGENT_BIN=$(printf '%s' "$readiness" | jq -r .runtime.executable)
  fm_dirname_to service_root "$STATE_FILE"
  case "$OMNIGENT_BIN" in
    "$service_root/"*) ;;
    *) fail 'readiness executable is outside the managed service root' ;;
  esac
  candidate=$OMNIGENT_BIN
  while :; do
    [ ! -L "$candidate" ] || fail "symlink in managed executable path: $candidate"
    [ "$candidate" != "$service_root" ] || break
    fm_dirname_to candidate "$candidate"
  done
  [ -f "$OMNIGENT_BIN" ] && [ -x "$OMNIGENT_BIN" ] || fail "managed executable is missing: $OMNIGENT_BIN"
  help=$(fm_run_timed 10 "$OMNIGENT_BIN" "$HARNESS" --help < /dev/null) || fail "$HARNESS capability probe failed"
  case "$help" in *'--env KEY=VALUE'*) ;; *) fail "$OMNIGENT_BIN lacks the native --env interface for $HARNESS" ;; esac
  health=$(curl --silent --show-error --fail --max-time 5 "${SERVER%/}/health") || fail "server is unreachable: $SERVER"
  printf '%s' "$health" | jq -e '.status == "ok"' >/dev/null 2>&1 || fail "server health failed: $SERVER"
  CLIENT_ENV=()
  while IFS= read -r entry; do CLIENT_ENV+=("$entry"); done < <(printf '%s' "$status" | jq -r '.client_environment | to_entries[] | "\(.key)=\(.value)"')
}

OP=${1:---help}
shift || true
case "$OP" in
  mode) [ "$#" -eq 1 ] || fail 'mode requires a config directory'; mode "$1"; exit ;;
  check|run|start) ;;
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit ;;
  *) fail "unknown operation: $OP" ;;
esac
DRY_RUN=0
if [ "${1:-}" = --dry-run ]; then DRY_RUN=1; shift; fi
HARNESS=${1:?a harness is required}
shift
if [ "$OP" = start ]; then
  case "$HARNESS" in claude|codex) ;; *) fail 'start supports Claude and Codex primaries' ;; esac
  [ "$#" -eq 0 ] || fail 'start takes only the primary harness'
fi
resolve_service
[ "$OP" != check ] || exit 0
ARGS=("$HARNESS" --server "$SERVER")
[ "$HARNESS" != claude ] || ARGS+=(--use-native-config)
# These names belong to Firstmate's existing launch contract. Never forward
# arbitrary ambient provider credentials, HOME, or the Omnigent-owned CODEX_HOME.
ENV_NAMES='FM_OMNIGENT FM_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_TRACE_CONTEXT FM_SUPERVISION_MODEL FM_TASK_ID COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST TRACEPARENT GOTMPDIR TMPDIR PATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK KIRO_HOME HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH'
export FM_OMNIGENT=on
for name in $ENV_NAMES; do
  case "$name" in
    # These owners treat empty as unset. Explicit empties also prevent stale
    # daemon routing or trace state from reappearing in a fresh native session.
    FM_*|HERDR_*|TRACEPARENT) ARGS+=(--env "$name=${!name-}") ;;
    *) if [ "${!name+x}" = x ]; then ARGS+=(--env "$name=${!name}"); fi ;;
  esac
done
for name in CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS FM_OMP_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI; do
  ARGS+=(--env "$name=")
done
if [ "$DRY_RUN" = 1 ]; then
  jq -n --arg executable "$OMNIGENT_BIN" --arg state_file "$STATE_FILE" --arg server_url "$SERVER" --arg harness "$HARNESS" \
    '{executable:$executable,harness:$harness,server_url:$server_url,state_file:$state_file}'
  exit 0
fi
NATIVE=("$@")
if [ "$OP" = run ]; then
  [ "${#NATIVE[@]}" -gt 0 ] || fail 'run requires the Firstmate native arguments'
  if [ "$HARNESS" = kiro ]; then
    [ "${NATIVE[0]}" = chat ] || fail 'expected the Kiro chat launch'
    NATIVE=("${NATIVE[@]:1}")
  fi
  if [ "$HARNESS" != agy ]; then
    last=$((${#NATIVE[@]} - 1))
    ARGS+=(--prompt "${NATIVE[last]}")
    NATIVE=("${NATIVE[@]:0:last}")
  fi
fi
# Codex, Kiro, and Antigravity sessions require their model as the
# wrapper's first-class option. Other flags remain byte-for-byte native argv.
REST=()
while [ "${#NATIVE[@]}" -gt 0 ]; do
  if { [ "$HARNESS" = codex ] || [ "$HARNESS" = kiro ] || [ "$HARNESS" = agy ]; } && [ "${NATIVE[0]}" = --model ]; then
    [ "${#NATIVE[@]}" -ge 2 ] || fail 'missing native model value'
    ARGS+=(--model "${NATIVE[1]}")
    NATIVE=("${NATIVE[@]:2}")
  else
    REST+=("${NATIVE[0]}")
    NATIVE=("${NATIVE[@]:1}")
  fi
done
# Omnigent attaches through tmux without -u. An ASCII supervisor locale makes
# that client replace native prompt glyphs with underscores, so the shared
# composer reader cannot prove safe steering or exit. Set only the attaching
# client's locale; the explicit native environment above remains independent.
client_locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
client_locale=$(locale -a | LC_ALL=C awk -v current="$client_locale" '
  tolower($0) ~ /[.]utf-?8$/ {
    if (!first) first=$0
    if ($0 == current) selected=$0
    if (tolower($0) == "en_us.utf-8" || tolower($0) == "en_us.utf8") english=$0
    if (tolower($0) == "c.utf8" || tolower($0) == "c.utf-8") neutral=$0
  }
  END { print selected ? selected : (neutral ? neutral : (english ? english : first)) }
') || fail 'cannot list installed locales for the native terminal attach'
[ -n "$client_locale" ] || fail 'an installed UTF-8 locale is required for the native terminal attach'
exec env "${CLIENT_ENV[@]}" LC_ALL="$client_locale" "$OMNIGENT_BIN" "${ARGS[@]}" -- "${REST[@]+${REST[@]}}"
