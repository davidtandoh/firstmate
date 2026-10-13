#!/usr/bin/env bash
# Omnigent launch boundary. The underlying harness remains dispatch/control identity.
# Usage: fm-omnigent.sh mode <config-dir>
#        fm-omnigent.sh check [--config <worker-config-dir>] <claude|codex|kiro|agy>
#        fm-omnigent.sh run [--dry-run] [--config <worker-config-dir>] <harness> <Firstmate native arguments...>
#        fm-omnigent.sh start [--dry-run] <claude|codex>
# mode: config/omnigent (auto|on, absent=auto) can force wrapping; otherwise
# OMNIGENT=1 enables wrapping before inherited FM_OMNIGENT (on|off).
# Invalid input refuses.
# check/run/start query the Kit runtime-receipt and separate telemetry policy
# afresh. The Kit resolves its own observation root (AGENT_KIT_OBSERVATION_DIR
# or its configured default); Firstmate never reconstructs that directory.
# The selected executable must return a matching public Omnigent launch receipt.
# Required collection denies new admission only. Trace degradation never owns
# running sessions. This command does not detach, stop, or adopt a session.
# --config enforces worker credential-removal/environment restrictions before
# preflight and again at pane execution. It does not change primary settings.
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

TELEMETRY_ENV_NAMES=(OMNIGENT_TELEMETRY_ENABLED OMNIGENT_OTEL_CAPTURE_CONTENT OMNIGENT_OTEL_HTTP_CLIENT_INSTRUMENTATION OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_HEADERS)

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

read_json() { # <safe-label> <seconds> <command...>; sets JSON_OUTPUT
  local label=$1 bound=$2 rc=0 category LC_ALL=C
  shift 2
  JSON_OUTPUT=$(fm_run_timed "$bound" "$@" < /dev/null 2>/dev/null | head -c 131073) || rc=$?
  fm_timed_out "$rc" && fail "$label timed out"
  [ "${#JSON_OUTPUT}" -le 131072 ] || fail "$label exceeds 128 KiB"
  printf '%s' "$JSON_OUTPUT" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || fail "invalid $label JSON"
  if [ "$rc" != 0 ]; then
    category=$(printf '%s' "$JSON_OUTPUT" | jq -L "$SCRIPT_DIR" -ser \
      'include "fm-omnigent-contract"; fm_omnigent_error_category // fm_pak_error_category' 2>/dev/null) || category=
    fail "$label refused${category:+: $category}"
  fi
}

resolve_service() {
  local selection receipt help candidate environment name help_rc=0 LC_ALL=C
  case "$HARNESS" in claude|codex|kiro|agy) ;; *) fail "unverified wrapped harness: $HARNESS" ;; esac
  command -v agent-kit >/dev/null 2>&1 || fail 'agent-kit is required on this host'
  command -v jq >/dev/null 2>&1 || fail 'jq is required on this host'
  read_json 'PAK runtime selector' 15 agent-kit observe serve runtime-receipt --json
  selection=$JSON_OUTPUT
  printf '%s' "$selection" | jq -L "$SCRIPT_DIR" -se \
    'include "fm-omnigent-contract"; fm_omnigent_selector_verified' >/dev/null 2>&1 || fail 'invalid PAK runtime selector'
  read_json 'PAK telemetry policy' 15 agent-kit observe serve telemetry --json
  POLICY=$JSON_OUTPUT
  printf '%s' "$POLICY" | jq -L "$SCRIPT_DIR" -se \
    'include "fm-omnigent-contract"; fm_omnigent_telemetry_verified' >/dev/null 2>&1 || fail 'invalid PAK telemetry policy'
  if [ "$(printf '%s' "$POLICY" | jq -r .admission)" = deny_new ]; then
    fail 'required_collection_unavailable: new admission denied; existing sessions preserved'
  fi
  if [ "$(printf '%s' "$POLICY" | jq -r .admission)" = allow_with_gap ]; then
    printf 'telemetry: degraded (telemetry_gap); new admission permitted; existing sessions preserved\n' >&2
  fi
  SERVER=$(printf '%s' "$selection" | jq -r .endpoint)
  OMNIGENT_BIN=$(printf '%s' "$selection" | jq -r .runtime.executable)
  RUNTIME=$(printf '%s' "$selection" | jq -c .runtime)
  INSTALLER_GENERATION=$(printf '%s' "$selection" | jq -r .installer.generation)
  environment=$(printf '%s' "$selection" | jq -r .installer.environment)
  candidate=$OMNIGENT_BIN
  while :; do
    [ ! -L "$candidate" ] || fail 'symlink in selected executable path'
    [ "$candidate" != "$environment" ] || break
    fm_dirname_to candidate "$candidate"
  done
  [ -f "$OMNIGENT_BIN" ] && [ -x "$OMNIGENT_BIN" ] || fail "managed executable is missing: $OMNIGENT_BIN"

  CLIENT_UNSET=(-u OMNIGENT_AUTH_PROVIDER -u OMNIGENT_CONFIG_HOME -u OMNIGENT_DATA_DIR -u OMNIGENT_LOCAL_SERVER_PORT -u OMNIGENT_WEB_BASE_PATH)
  for name in "${TELEMETRY_ENV_NAMES[@]}" "${!OTEL_@}"; do CLIENT_UNSET+=(-u "$name"); done
  SELECTED_ENV=()
  while IFS= read -r entry; do SELECTED_ENV+=("$entry"); done < <(printf '%s' "$selection" | jq -r '.client_environment | to_entries[] | "\(.key)=\(.value)"')
  read_json 'Omnigent launch receipt' 10 env "${CLIENT_UNSET[@]}" "${SELECTED_ENV[@]}" \
    "$OMNIGENT_BIN" runtime launch-contract --server "$SERVER" --json
  receipt=$JSON_OUTPUT
  printf '%s' "$receipt" | jq -L "$SCRIPT_DIR" -se --argjson runtime "$RUNTIME" --arg server "$SERVER" \
    --argjson environment "$(printf '%s' "$selection" | jq -c .client_environment)" --arg harness "$HARNESS" \
    'include "fm-omnigent-contract"; fm_omnigent_runtime_matches($runtime; $server; $environment) and fm_omnigent_harness_verified($harness)' \
    >/dev/null 2>&1 || fail 'Omnigent runtime, endpoint, environment, or capability receipt mismatch'
  help=$(fm_run_timed 10 env "${CLIENT_UNSET[@]}" "${SELECTED_ENV[@]}" "$OMNIGENT_BIN" "$HARNESS" --help < /dev/null 2>/dev/null | head -c 32769) || help_rc=$?
  [ "$help_rc" = 0 ] && [ "${#help}" -le 32768 ] || fail "$HARNESS capability probe failed"
  case "$help" in *'--env KEY=VALUE'*) ;; *) fail "$OMNIGENT_BIN lacks the native --env interface for $HARNESS" ;; esac
  CLIENT_ENV=()
  while IFS= read -r entry; do CLIENT_ENV+=("$entry"); done < <(printf '%s\n%s' "$selection" "$POLICY" | jq -sr '.[0].client_environment + .[1].client_environment | to_entries[] | "\(.key)=\(.value)"')
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
WORKER_CONFIG=
if [ "${1:-}" = --config ]; then
  [ "$OP" != start ] || fail 'start does not take worker configuration'
  [ "$#" -ge 3 ] && [ -n "$2" ] || fail '--config requires a directory and harness'
  WORKER_CONFIG=$2
  shift 2
fi
HARNESS=${1:?a harness is required}
shift
if [ -n "$WORKER_CONFIG" ]; then
  [ ! -e "$WORKER_CONFIG/launch-env-allowlist" ] && [ ! -L "$WORKER_CONFIG/launch-env-allowlist" ] \
    || fail 'cannot enforce config/launch-env-allowlist across the daemon boundary'
  if [ "$HARNESS" = claude ] && { [ -e "$WORKER_CONFIG/claude-account" ] || [ -L "$WORKER_CONFIG/claude-account" ]; }; then
    fail 'cannot enforce config/claude-account credential removal across the daemon boundary'
  fi
fi
if [ "$OP" = check ]; then [ "$#" = 0 ] || fail 'check takes only configuration and harness'; fi
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
ENV_NAMES='FM_OMNIGENT FM_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_TRACE_CONTEXT FM_SUPERVISION_MODEL FM_TASK_ID COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST TRACEPARENT GOTMPDIR TMPDIR PATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK KIRO_HOME HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH AGENT_KIT_OBSERVATION_DIR'
export FM_OMNIGENT=on
for name in $ENV_NAMES; do
  case "$name" in
    # These owners treat empty as unset. Explicit empties also prevent stale
    # daemon routing or trace state from reappearing in a fresh native session.
    FM_*|HERDR_*|TRACEPARENT) ARGS+=(--env "$name=${!name-}") ;;
    *) if [ "${!name+x}" = x ]; then ARGS+=(--env "$name=${!name}"); fi ;;
  esac
done
for name in "${TELEMETRY_ENV_NAMES[@]}"; do
  value=$(printf '%s' "$POLICY" | jq -r --arg name "$name" '.client_environment[$name] // ""')
  ARGS+=(--env "$name=$value")
done
for name in CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS FM_OMP_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI; do
  ARGS+=(--env "$name=")
done
if [ "$DRY_RUN" = 1 ]; then
  printf '%s' "$POLICY" | jq --arg executable "$OMNIGENT_BIN" --arg server_url "$SERVER" --arg harness "$HARNESS" \
    --argjson runtime "$RUNTIME" --arg installer_generation "$INSTALLER_GENERATION" \
    '{executable:$executable,harness:$harness,server_url:$server_url,runtime:$runtime,installer_generation:$installer_generation,
      telemetry:{admission,reason,capture_enabled,collection_required,delivery_available,loss,retry,existing_sessions,durable_acceptance}}'
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
exec env "${CLIENT_UNSET[@]}" "${CLIENT_ENV[@]}" LC_ALL="$client_locale" "$OMNIGENT_BIN" "${ARGS[@]}" -- "${REST[@]+${REST[@]}}"
