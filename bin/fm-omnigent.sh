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
# Session title roles and safety boundaries: docs/omnigent.md#session-titles.
# Record wait: 180 seconds; each HTTP request: 5 seconds within a 6-second
# process bound, at most 128 KiB of JSON. No naming retry or session backfill.
# Preflight shares a 50-second external-command budget (status 20s, readiness
# 15s, capability 10s, health 5s), retaining Kit process-identity verification.
# FM_TIMING_LOG records each stage through fm-timing-lib.sh; stages taking 3s
# or failing also report their name, elapsed time and bound on stderr.
# Kit's internal status stages remain Kit-owned; this boundary measures the
# complete status command rather than guessing which internal probe was slow.
# _title-session is the private bounded API operation used by the stderr reader.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

fail() {
  [ -z "${PREFLIGHT_STARTED:-}" ] || fm_timing_record omnigent-preflight total "$PREFLIGHT_STARTED" failed
  printf 'error: Omnigent launch: %s\n' "$*" >&2
  exit 1
}
title_fail() { printf 'error: Omnigent session title: %s\n' "$*" >&2; exit 1; }

session_request() { # <GET|PATCH> [title JSON]
  local rc=0
  local LC_ALL=C
  local args=(--silent --show-error --fail --max-time 5 --noproxy '*' --proto '=http' --request "$1")
  [ "$#" -lt 2 ] || args+=(--header 'Content-Type: application/json' --data "$2")
  REQUEST_RESULT=$(fm_run_timed 6 curl "${args[@]}" \
    "${SERVER%/}/v1/sessions/$SESSION_ID" | head -c 131073) || rc=$?
  [ "$rc" = 0 ] || title_fail "session $SESSION_ID: $1 failed (exit $rc)"
  [ "${#REQUEST_RESULT}" -le 131072 ] || title_fail "session $SESSION_ID: oversized $1 response"
  printf '%s' "$REQUEST_RESULT" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || title_fail "session $SESSION_ID: invalid $1 response"
}

title_session() { # <server> <session-id> <harness> <title> <launch epoch>
  [ "$#" -eq 5 ] || title_fail 'invalid private naming request'
  SERVER=$1 SESSION_ID=$2
  local wrapper title=$4 started=$5 payload
  [[ "$SERVER" =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/?$ ]] || title_fail 'invalid server'
  [[ "$SESSION_ID" =~ ^[a-f0-9]{32}$ ]] || title_fail 'invalid session id'
  [[ "$started" =~ ^[0-9]+$ ]] || title_fail 'invalid launch epoch'
  case "$3" in
    claude) wrapper=claude-code-native-ui ;;
    codex) wrapper=codex-native-ui ;;
    kiro) wrapper=kiro-native-ui ;;
    agy) wrapper=antigravity-native-ui ;;
    *) title_fail 'invalid harness' ;;
  esac
  session_request GET
  printf '%s' "$REQUEST_RESULT" | jq -e --arg id "$SESSION_ID" --arg wrapper "$wrapper" --argjson started "$started" '
    .id == $id and .labels["omnigent.wrapper"] == $wrapper and
    (.created_at | type == "number" and . >= $started)
  ' >/dev/null 2>&1 || title_fail "session $SESSION_ID: launch identity verification failed"
  payload=$(jq -cn --arg title "$title" '{title:$title}')
  session_request PATCH "$payload"
  printf '%s' "$REQUEST_RESULT" | jq -e --arg id "$SESSION_ID" --arg title "$title" '.id == $id and .title == $title' >/dev/null 2>&1 \
    || title_fail "session $SESSION_ID: PATCH did not confirm the requested title"
}
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

preflight_stage() { # <stage> <stage-cap-seconds> <command...>
  local stage=$1 cap=$2 start now remaining bound rc=0 elapsed
  shift 2
  start=$(fm_timing_now_ms)
  remaining=$(( (PREFLIGHT_DEADLINE - start) / 1000 ))
  if [ "$remaining" -lt 1 ]; then
    printf 'error: Omnigent preflight stage=%s timed out: total budget exhausted\n' "$stage" >&2
    return 124
  fi
  bound=$cap
  [ "$remaining" -ge "$cap" ] || bound=$remaining
  fm_run_timed "$bound" "$@" || rc=$?
  now=$(fm_timing_now_ms)
  elapsed=$(( now - start ))
  fm_timing_record omnigent-preflight "$stage" "$start" "exit-$rc"
  if [ "$elapsed" -ge 3000 ] || [ "$rc" -ne 0 ]; then
    printf 'Omnigent preflight stage=%s elapsed_ms=%s bound_s=%s exit=%s' "$stage" "$elapsed" "$bound" "$rc" >&2
    if fm_timed_out "$rc"; then printf ' timed out' >&2; fi
    printf '\n' >&2
  fi
  return "$rc"
}

resolve_service() {
  local status readiness reason help health candidate service_root status_rc=0 readiness_rc=0 budget=50
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    budget=${FM_TEST_OMNIGENT_PREFLIGHT_BUDGET:-50}
    case "$budget" in ''|*[!0-9]*) fail 'invalid test preflight budget' ;; esac
    [ "$budget" -ge 1 ] && [ "$budget" -le 50 ] || fail 'invalid test preflight budget'
  fi
  PREFLIGHT_STARTED=$(fm_timing_now_ms)
  PREFLIGHT_DEADLINE=$(( PREFLIGHT_STARTED + budget * 1000 ))
  case "$HARNESS" in claude|codex|kiro|agy) ;; *) fail "unverified wrapped harness: $HARNESS" ;; esac
  command -v agent-kit >/dev/null 2>&1 || fail 'agent-kit is required on this host'
  command -v jq >/dev/null 2>&1 || fail 'jq is required on this host'
  command -v curl >/dev/null 2>&1 || fail 'curl is required on this host'
  status=$(preflight_stage status 20 agent-kit observe serve status --json < /dev/null | head -c 131073) || status_rc=$?
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
  readiness=$(preflight_stage readiness 15 agent-kit observe serve status --readiness --json < /dev/null | head -c 131073) || readiness_rc=$?
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
  help=$(preflight_stage capability 10 "$OMNIGENT_BIN" "$HARNESS" --help < /dev/null) || fail "$HARNESS capability probe failed"
  case "$help" in *'--env KEY=VALUE'*) ;; *) fail "$OMNIGENT_BIN lacks the native --env interface for $HARNESS" ;; esac
  health=$(preflight_stage health 5 curl --silent --show-error --fail --max-time 5 "${SERVER%/}/health") || fail "server is unreachable: $SERVER"
  printf '%s' "$health" | jq -e '.status == "ok"' >/dev/null 2>&1 || fail "server health failed: $SERVER"
  CLAUDE_ACCOUNT_ENFORCEMENT=0
  if printf '%s' "$status" | jq -e '
    .omnigent.repository == "https://github.com/davidtandoh/omnigent.git" and
    (.omnigent.commit == "ee228c44a98dd36c149f73025905817b003282c0" or
     .omnigent.commit == "bea4e262f08245deabed86a9b1eb4cafbcac1423")
  ' >/dev/null 2>&1; then
    CLAUDE_ACCOUNT_ENFORCEMENT=1
  fi
  if [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_ACCOUNT_ENFORCEMENT" != 1 ]; then
    fail 'running daemon lacks verified exact Claude account enforcement; choose another worker or update Omnigent before selecting this account'
  fi
  fm_timing_record omnigent-preflight total "$PREFLIGHT_STARTED" passed
  PREFLIGHT_STARTED=
  CLIENT_ENV=()
  while IFS= read -r entry; do CLIENT_ENV+=("$entry"); done < <(printf '%s' "$status" | jq -r '.client_environment | to_entries[] | "\(.key)=\(.value)"')
}

OP=${1:---help}
shift || true
case "$OP" in
  _title-session) title_session "$@"; exit ;;
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
ENV_NAMES='FM_FRESH_TOKEN FM_OMNIGENT FM_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_TRACE_CONTEXT FM_SUPERVISION_MODEL FM_TASK_ID COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST TRACEPARENT GOTMPDIR TMPDIR PATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK KIRO_HOME HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH'
export FM_OMNIGENT=on
for name in $ENV_NAMES; do
  case "$name" in
    # An explicit empty selector clears a daemon's inherited account. Native
    # Claude enforcement in Omnigent preserves non-empty selectors verbatim.
    CLAUDE_CONFIG_DIR) if [ "$HARNESS" = claude ]; then
      [ "$CLAUDE_ACCOUNT_ENFORCEMENT" != 1 ] || ARGS+=(--env "$name=${!name-}")
    elif [ "${!name+x}" = x ]; then ARGS+=(--env "$name=${!name}"); fi ;;
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
command -v python3 >/dev/null 2>&1 || fail 'python3 is required for launch title observation'
TITLE=firstmate
TITLE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-${SCRIPT_DIR%/bin}}}
fm_basename_to TITLE_HOME "$TITLE_HOME"
if [ "$OP" = run ] && [ -n "${FM_TASK_ID:-}" ]; then
  TITLE="$TITLE_HOME · $FM_TASK_ID"
elif [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
  TITLE="$TITLE_HOME · firstmate"
fi
printf '%s' "$TITLE" | jq -eRs 'length > 0 and (test("[\u0000-\u001f\u007f]") | not)' >/dev/null || fail 'invalid session title identity'
TITLE_STARTED=$(date +%s)
# Keep the native wrapper as the foreground exec owner. Only its diagnostic
# stderr enters the invocation-private reader; terminal attach/stdin/stdout,
# signals and native exit status retain the existing transport owner.
exec env "${CLIENT_ENV[@]}" LC_ALL="$client_locale" "$OMNIGENT_BIN" "${ARGS[@]}" -- "${REST[@]+${REST[@]}}" \
  2> >(python3 "$SCRIPT_DIR/fm-omnigent-title.py" --server "$SERVER" --harness "$HARNESS" \
    --title "$TITLE" --started "$TITLE_STARTED" --launcher "$SCRIPT_DIR/fm-omnigent.sh")
