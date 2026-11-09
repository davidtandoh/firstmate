#!/usr/bin/env bash
# Omnigent launch boundary. The underlying harness remains dispatch/control identity.
# Usage: fm-omnigent.sh mode <config-dir>
#        fm-omnigent.sh check <claude|codex|kiro|agy>
#        fm-omnigent.sh run [--dry-run] <harness> <Firstmate native arguments...>
#        fm-omnigent.sh start [--dry-run] <claude|codex>
#        fm-omnigent.sh archive [--dry-run] <task-meta>
#        fm-omnigent.sh probe <task-meta>
#        fm-omnigent.sh approvals <task-meta>
#        fm-omnigent.sh binding [<task-meta>]
# mode: config/omnigent (auto|on, absent=auto) can force wrapping; otherwise
# OMNIGENT=1 enables wrapping before inherited FM_OMNIGENT (on|off).
# Invalid input refuses.
# check/start and unbound run resolve the local Kit's serve status afresh,
# unless FM_OMNIGENT_SERVER and FM_OMNIGENT_HOST name a parent's server and
# this host's registered Omnigent host id (remote-server mode). That mode needs
# no Kit: it uses the omnigent on PATH, requires the runtime Python beside its
# real path to report this host's identity as that exact id, and requires the
# server's /v1/hosts/<id> to report it online. Its client environment is empty.
# An https server is valid only as that explicit parent server: the launch's
# FM_OMNIGENT_SERVER, or a record's own omnigent_remote_server. Local launches
# forward neither variable.
# binding prints server=/host= lines for that pair, taken from the environment
# or, when both variables are empty, from the task record's
# omnigent_remote_server=/omnigent_remote_host= lines; a partial pair refuses.
# Spawn check can publish FM_OMNIGENT_PREFLIGHT, a private single-use record
# bound to FM_OMNIGENT_RECORD_GEN. It carries the verified server URL, state
# file, client environment, executable identity, account and capability flags.
# Bound run requires FM_OMNIGENT_RECORD_META to name the same unretired
# generation, and verifies the harness, Claude selector, executable identity
# and /health without repeating status, readiness or capability probing.
# A remote-server record also carries the host id; its session must report it.
# Invalid records refuse launch.
# The client is readiness runtime.executable, never a PATH install.
# Wrapper capability flags are cached per harness under state/ in owner-only
# JSON files, keyed by executable real path, inode and nanosecond mtime.
# Inode and mtime use decimal strings to preserve exact identity through jq.
# Identity mismatch or invalid cache data requires a new help probe. Status,
# readiness, health and account lookup stay fresh for full preflight; dry-run
# never writes a cache.
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
# process bound; naming and archive responses are limited to 128 KiB of JSON.
# No naming retry or session backfill.
# Full preflight shares a 50-second external-command budget (status 20s, readiness
# and capability whatever remains, health 5s, Claude account lookup 10s),
# retaining Kit process-identity verification.
# A Claude launch with a non-empty CLAUDE_CONFIG_DIR asks the runtime's own
# Python which configured account (a kind: subscription, cli: claude provider
# claude-<name> in OMNIGENT_CONFIG_HOME/config.yaml) owns that exact folder;
# a match launches with --account <name> instead of --env CLAUDE_CONFIG_DIR.
# A spawn launch passes FM_OMNIGENT_RECORD_META, FM_OMNIGENT_RECORD_GEN,
# FM_OMNIGENT_HOME_ID and FM_OMNIGENT_TASK. The verified session is then
# recorded as omnigent_session=/omnigent_server= in that task record (record
# lock wait 150s, only while its spawn_gen still matches) and labelled
# firstmate.home=<home hash> and firstmate.task=<task id>.
# archive PATCHes {"archived":true} for the recorded session only, never
# delete_worktree; it prints a warning and exits 1 on failure, and does nothing
# without a recorded session. Callers archive only a proven-stopped worker.
# probe prints alive, dead or unknown for the recorded session from one bounded
# GET of /health and one of /v1/sessions/<id>.
# approvals prints a JSON array of {id,summary}, [] when cleared, or unknown.
# Its single session GET has the same time bound and a 2 MiB response limit.
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
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# A local Kit serves loopback HTTP; a parent's server reaches a remote host only
# as an HTTPS origin with no path. Recorded bindings may name either.
LOCAL_SERVER_RE='^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/?$'
REMOTE_SERVER_RE='^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$'
HOST_ID_RE='^[a-f0-9]{32}$'
# <server> [explicit parent server]: an HTTPS origin counts only when it is
# exactly the parent server this launch or record names explicitly.
server_valid() {
  [[ "$1" =~ $LOCAL_SERVER_RE ]] && return 0
  [ -n "${2:-}" ] && [[ "$1" =~ $REMOTE_SERVER_RE ]] && [ "${1%/}" = "${2%/}" ]
}

fail() {
  [ -z "${PREFLIGHT_STARTED:-}" ] || fm_timing_record omnigent-preflight total "$PREFLIGHT_STARTED" failed
  printf 'error: Omnigent launch: %s\n' "$*" >&2
  exit 1
}
title_fail() { printf 'error: Omnigent session title: %s\n' "$*" >&2; exit 1; }

session_request() { # <GET|PATCH> [JSON body]; sets REQUEST_RESULT or REQUEST_ERROR
  local rc=0
  local LC_ALL=C
  local args=(--silent --show-error --fail --max-time 5 --noproxy '*' --proto '=http,https' --request "$1")
  [ "$#" -lt 2 ] || args+=(--header 'Content-Type: application/json' --data "$2")
  REQUEST_ERROR=
  REQUEST_RESULT=$(fm_run_timed 6 curl "${args[@]}" \
    "${SERVER%/}/v1/sessions/$SESSION_ID" | head -c 131073) || rc=$?
  if [ "$rc" != 0 ]; then REQUEST_ERROR="session $SESSION_ID: $1 failed (exit $rc)"; return 1; fi
  if [ "${#REQUEST_RESULT}" -gt 131072 ]; then REQUEST_ERROR="session $SESSION_ID: oversized $1 response"; return 1; fi
  printf '%s' "$REQUEST_RESULT" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || { REQUEST_ERROR="session $SESSION_ID: invalid $1 response"; return 1; }
}

title_session() { # <server> <session-id> <harness> <title> <launch epoch>
  [ "$#" -eq 5 ] || title_fail 'invalid private naming request'
  SERVER=$1 SESSION_ID=$2
  local wrapper title=$4 started=$5 payload
  server_valid "$SERVER" "${FM_OMNIGENT_SERVER:-}" || title_fail 'invalid server'
  [[ "$SESSION_ID" =~ ^[a-f0-9]{32}$ ]] || title_fail 'invalid session id'
  # A remote-server launch must have created its session on the registered host.
  [ -z "${FM_OMNIGENT_HOST:-}" ] || [[ "$FM_OMNIGENT_HOST" =~ $HOST_ID_RE ]] || title_fail 'invalid host identity'
  [[ "$started" =~ ^[0-9]+$ ]] || title_fail 'invalid launch epoch'
  case "$3" in
    claude) wrapper=claude-code-native-ui ;;
    codex) wrapper=codex-native-ui ;;
    kiro) wrapper=kiro-native-ui ;;
    agy) wrapper=antigravity-native-ui ;;
    *) title_fail 'invalid harness' ;;
  esac
  session_request GET || title_fail "$REQUEST_ERROR"
  printf '%s' "$REQUEST_RESULT" | jq -e --arg id "$SESSION_ID" --arg wrapper "$wrapper" --argjson started "$started" \
    --arg host "${FM_OMNIGENT_HOST:-}" '
    .id == $id and .labels["omnigent.wrapper"] == $wrapper and
    (.created_at | type == "number" and . >= $started) and
    ($host == "" or (.host_id | type == "string" and (ascii_downcase | gsub("-"; "")) == $host))
  ' >/dev/null 2>&1 || title_fail "session $SESSION_ID: launch identity verification failed"
  # Record before naming: retirement depends on the recorded identity, while a
  # rejected title or label PATCH only affects presentation.
  [ -z "${FM_OMNIGENT_RECORD_META:-}" ] || record_session "$FM_OMNIGENT_RECORD_META" "${FM_OMNIGENT_RECORD_GEN:-}" || return 0
  # Omnigent merges PATCH labels into the existing set, so the wrapper's own
  # labels survive. Only a spawn-supplied identity adds Firstmate labels.
  labels='{}'
  if [ -n "${FM_OMNIGENT_HOME_ID:-}" ]; then
    [[ "$FM_OMNIGENT_HOME_ID" =~ ^[0-9a-f]{64}$ ]] || title_fail 'invalid home identity'
    [[ "${FM_OMNIGENT_TASK:-}" =~ ^[A-Za-z0-9._-]+$ ]] || title_fail 'invalid task identity'
    labels=$(jq -cn --arg home "$FM_OMNIGENT_HOME_ID" --arg task "$FM_OMNIGENT_TASK" \
      '{"firstmate.home":$home,"firstmate.task":$task}')
  fi
  payload=$(jq -cn --arg title "$title" --argjson labels "$labels" \
    'if $labels == {} then {title:$title} else {title:$title,labels:$labels} end')
  session_request PATCH "$payload" || title_fail "$REQUEST_ERROR"
  printf '%s' "$REQUEST_RESULT" | jq -e --arg id "$SESSION_ID" --arg title "$title" '.id == $id and .title == $title' >/dev/null 2>&1 \
    || title_fail "session $SESSION_ID: PATCH did not confirm the requested title"
  printf '%s' "$REQUEST_RESULT" | jq -e --argjson labels "$labels" \
    '(.labels // {}) as $have | all($labels | to_entries[]; $have[.key] == .value)' >/dev/null 2>&1 \
    || title_fail "session $SESSION_ID: PATCH did not confirm the Firstmate labels"
}
# Bind this launch's verified session into its task record, under the record
# lock and only while the record still names the launching spawn generation, so
# a superseded or rolled-back launch can never overwrite a newer binding.
record_session() { # <absolute task meta> <spawn generation>
  local meta=$1 gen=$2 dir base locked=${3:-0} pending
  [[ "$meta" == /*.meta ]] && [[ "$gen" =~ ^[A-Za-z0-9._-]+$ ]] || title_fail 'invalid task record binding'
  fm_dirname_to dir "$meta"
  fm_basename_to base "$meta"
  local -x FM_STATE_OVERRIDE="$dir"
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    pending="$dir/.${base%.meta}.omnigent.$gen.meta"
    tmp="$pending.${BASHPID:-$$}"
    if [ "$locked" != 1 ]; then
      if {
        printf 'spawn_gen=%s\nomnigent_session=%s\nomnigent_server=%s\nomnigent_attach_pid=%s\nomnigent_attach_start=%s\n' \
          "$gen" "$SESSION_ID" "${SERVER%/}" "${FM_OMNIGENT_ATTACH_PID:-}" "${FM_OMNIGENT_ATTACH_START:-}" &&
        printf 'omnigent_remote_server=%s\n' "${FM_OMNIGENT_SERVER:-}"
      } > "$tmp"; then
        fm_backlog_atomic_transition publish "$tmp" "$pending" 'session handoff' "$dir" \
          || title_fail "session handoff update failed: $meta"
      else
        title_fail "session handoff update failed: $meta"
      fi
    fi
    lock=$(fm_meta_lock_path "$meta") || title_fail 'invalid task record path'
    if [ "$locked" != 1 ]; then
      fm_lock_acquire_wait_bounded "$lock" 150 || title_fail "task record lock unavailable: $meta"
    fi
    tmp="$dir/.${base%.meta}.meta.omnigent.${BASHPID:-$$}"
    status=0
    if ! fm_backlog_meta_spawn_gen "$meta" "$dir" || [ "$FM_BACKLOG_META_SPAWN_GEN" != "$gen" ] ||
       [ "$(fm_meta_get "$meta" omnigent_retired_gen)" = "$gen" ]; then
      archive_bound_session || true
      printf 'error: Omnigent session title: session %s: task record no longer names this launch; not recorded\n' "$SESSION_ID" >&2
      status=1
    elif ! {
      printf 'omnigent_session=%s\nomnigent_server=%s\nomnigent_attach_pid=%s\nomnigent_attach_start=%s\n' \
        "$SESSION_ID" "${SERVER%/}" "${FM_OMNIGENT_ATTACH_PID:-}" "${FM_OMNIGENT_ATTACH_START:-}" &&
      awk -F= '$1 != "omnigent_session" && $1 != "omnigent_server" && $1 != "omnigent_attach_pid" && $1 != "omnigent_attach_start"' "$meta"
    } > "$tmp" ||
      ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$dir"; then
      rm -f "$tmp"
      printf 'error: Omnigent session title: session %s: task record update failed\n' "$SESSION_ID" >&2
      status=1
    fi
    rm -f "$pending"
    [ "$locked" = 1 ] || fm_lock_release "$lock"
    exit "$status"
  )
}

capture_session() {
  local locked=0 meta capture_dir base gen pending lock status=0 attempt
  if [ "${1:-}" = --record-locked ]; then locked=1; shift; fi
  [ "$#" -eq 1 ] || fail 'capture requires one task record'
  meta=$1
  fm_dirname_to capture_dir "$meta"
  fm_basename_to base "$meta"
  export FM_STATE_OVERRIDE="$capture_dir"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  lock=$(fm_meta_lock_path "$meta") || return 1
  if [ "$locked" = 0 ]; then
    fm_lock_acquire_wait_bounded "$lock" 10 || return 1
  fi
  if read_binding "$meta" && [ -n "$SESSION_ID" ]; then
    [ "$locked" = 1 ] || fm_lock_release "$lock"
    return 0
  fi
  if fm_backlog_meta_spawn_gen "$meta" "$capture_dir"; then
    gen=$FM_BACKLOG_META_SPAWN_GEN
    pending="$capture_dir/.${base%.meta}.omnigent.$gen.meta"
    for ((attempt=0; attempt<100; attempt++)); do
      [ ! -f "$pending" ] || break
      sleep 0.1
    done
    if [ "$(fm_meta_get "$pending" spawn_gen)" = "$gen" ] &&
       read_binding "$pending" && [ -n "$SESSION_ID" ]; then
      FM_OMNIGENT_ATTACH_PID=$(fm_meta_get "$pending" omnigent_attach_pid) \
        FM_OMNIGENT_ATTACH_START=$(fm_meta_get "$pending" omnigent_attach_start) \
        record_session "$meta" "$gen" 1 || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  [ "$locked" = 1 ] || fm_lock_release "$lock"
  if [ "$status" != 0 ]; then
    printf 'warning: Omnigent capture: no verified session handoff for %s before retirement\n' "$meta" >&2
  fi
  return "$status"
}

# Read one recorded launch binding. Empty values mean no wrapped launch was
# recorded; anything present must be exactly what record_session writes.
read_binding() { # <task meta>
  local meta=$1 parent
  [ -f "$meta" ] && [ ! -L "$meta" ] || { BINDING_ERROR="task record missing: $meta"; return 1; }
  SESSION_ID=$(awk -F= '$1 == "omnigent_session" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta") || return 1
  SERVER=$(awk -F= '$1 == "omnigent_server" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta") || return 1
  [ -n "$SESSION_ID$SERVER" ] || return 0
  # Only the record's own parent-server binding admits an HTTPS session server.
  parent=$(awk -F= '$1 == "omnigent_remote_server" { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$meta") || return 1
  if [[ ! "$SESSION_ID" =~ ^[a-f0-9]{32}$ ]] || [ "$SERVER" != "${SERVER%/}" ] || ! server_valid "$SERVER" "$parent"; then
    BINDING_ERROR="invalid recorded Omnigent session in $meta"
    return 1
  fi
}

# Archive exactly the recorded session. Never sends delete_worktree: the
# session workspace is a shared worktree slot. Archive stops the session's
# runner, so callers invoke it only after the worker is proven stopped.
archive_session() { # [--dry-run] <task meta>
  local dry=0 locked=0 meta dir lock tmp gen status=0
  if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
  if [ "${1:-}" = --record-locked ]; then locked=1; shift; fi
  [ "$#" -eq 1 ] || fail 'archive requires one task record'
  meta=$1
  fm_dirname_to dir "$meta"
  export FM_STATE_OVERRIDE="$dir"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  lock=$(fm_meta_lock_path "$meta") || return 1
  if [ "$dry" = 0 ] && [ "$locked" = 0 ]; then
    fm_lock_acquire_wait_bounded "$lock" 10 || return 1
  fi
  if [ "$dry" = 0 ]; then
    if fm_backlog_meta_spawn_gen "$meta" "$dir"; then
      gen=$FM_BACKLOG_META_SPAWN_GEN
      tmp="$meta.omnigent.${BASHPID:-$$}"
      if {
        printf 'omnigent_retired_gen=%s\n' "$gen" &&
        awk -F= '$1 != "omnigent_retired_gen"' "$meta"
      } > "$tmp"; then
        fm_backlog_atomic_transition publish "$tmp" "$meta" 'task record' "$dir" || status=1
      else
        status=1
      fi
      rm -f "$tmp"
    fi
    [ "$locked" = 1 ] || fm_lock_release "$lock"
    [ "$status" = 0 ] || return 1
  fi
  BINDING_ERROR=
  read_binding "$1" || { printf 'warning: Omnigent archive: %s\n' "${BINDING_ERROR:-unreadable task record}" >&2; return 1; }
  [ -n "$SESSION_ID" ] || return 0
  if [ "$dry" = 1 ]; then
    printf 'would archive Omnigent session %s/v1/sessions/%s\n' "$SERVER" "$SESSION_ID"
    return 0
  fi
  archive_bound_session
}

archive_bound_session() {
  if ! session_request PATCH '{"archived":true}' ||
    ! printf '%s' "$REQUEST_RESULT" | jq -e --arg id "$SESSION_ID" '.id == $id and .archived == true' >/dev/null 2>&1; then
    printf 'warning: Omnigent archive: %s\n' "${REQUEST_ERROR:-session $SESSION_ID: archive was not confirmed}" >&2
    return 1
  fi
  printf 'archived Omnigent session %s\n' "$SESSION_ID"
}

# Classify the recorded session for supervision. Prints alive, dead or unknown.
# dead means the server is unreachable or the record proves the session's
# runner is gone, failed, archived or deleted. No binding, or a reply that
# proves neither, is unknown. One bounded request each; never retried here.
probe_session() ( # <task meta>
  local code body
  [ "$#" -eq 1 ] || fail 'probe requires one task record'
  if ! read_binding "$1" || [ -z "$SESSION_ID" ]; then echo unknown; return 0; fi
  if ! fm_run_timed 6 curl --silent --show-error --fail --max-time 5 --noproxy '*' --proto '=http,https' \
    "$SERVER/health" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1; then
    echo dead; return 0
  fi
  # Keep large records out of shell pattern expansion so parsing cannot stall supervision.
  body=$(mktemp "${TMPDIR:-/tmp}/fm-omnigent-probe.XXXXXX") || { echo unknown; return 0; }
  trap 'rm -f -- "$body"' EXIT
  session_snapshot "$body" || { echo unknown; return 0; }
  case "$code" in
    404) echo dead; return 0 ;;
    200) ;;
    *) echo unknown; return 0 ;;
  esac
  if jq -e --arg id "$SESSION_ID" '.id == $id and
    (.archived == true or .status == "failed" or .runner_online == false)' "$body" >/dev/null 2>&1; then
    echo dead
  elif jq -e --arg id "$SESSION_ID" '.id == $id and .runner_online == true' "$body" >/dev/null 2>&1; then
    echo alive
  else
    echo unknown
  fi
)
# Shared session lookup for supervision; caller owns the temporary body file.
# Keep response parsing off shell variables and bound both time and disk use.
session_snapshot() { # <output file>; sets code
  code=$(fm_run_timed 6 curl --silent --max-time 5 --max-filesize 2097152 --noproxy '*' --proto '=http,https' \
    --output "$1" --write-out '%{http_code}' "$SERVER/v1/sessions/$SESSION_ID" 2>/dev/null)
}

# Read-only approval snapshot: JSON array of correlation ids and safe summaries,
# or literal unknown. Never copy content_preview, tool arguments or raw messages.
# Only a recognized prompt heading is safe to expose; other wording is generic.
approvals_session() ( # <task meta>
  local body code
  [ "$#" -eq 1 ] || fail 'approvals requires one task record'
  if ! read_binding "$1" || [ -z "$SESSION_ID" ]; then echo unknown; return 0; fi
  body=$(mktemp "${TMPDIR:-/tmp}/fm-omnigent-approvals.XXXXXX") || { echo unknown; return 0; }
  trap 'rm -f -- "$body"' EXIT
  session_snapshot "$body" && [ "$code" = 200 ] || { echo unknown; return 0; }
  jq -sce --arg id "$SESSION_ID" '
    if length == 1 then .[0] else error("multiple session records") end |
    select(.id == $id and .runner_online == true and .archived != true and .status != "failed") |
    .pending_elicitations | select(type == "array") |
    if all(.[]; (.elicitation_id | type == "string" and length > 0) and (.params.message | type == "string")) then
      map({id: .elicitation_id, summary: (
        (.params.message | capture("^(?<heading>[A-Za-z]+ wants to call (?:\\*\\*)?[A-Za-z0-9_.:-]+)").heading | gsub("\\*"; "") | .[0:120])
        // "approval prompt (open Omnigent for details)")})
    else error("invalid approval") end
  ' "$body" 2>/dev/null || echo unknown
)

stop_attach() {
  local meta=$1 pid started current pgid
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  pid=$(fm_meta_get "$meta" omnigent_attach_pid)
  started=$(fm_meta_get "$meta" omnigent_attach_start)
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ -n "$started" ] || return 1
  [ "$(probe_session "$meta")" = dead ] || return 1
  current=$(fm_pid_start_time "$pid") || return 1
  [ "$current" = "$started" ] || return 1
  pgid=$(LC_ALL=C ps -p "$pid" -o pgid= | tr -d '[:space:]') || return 1
  [ "$pgid" = "$pid" ] || return 1
  kill -TERM -- "-$pid"
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

# Persistence and executable identity share the bounded record primitives.
# No saved record is evaluated as shell code. A bad
# launch handoff refuses rather than silently switching to a different runtime.
preflight_record() { # <action> <path> [values...]
  python3 -I -S - "$SCRIPT_DIR" "$@" <<'PY'
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
sys.path.insert(0, sys.argv.pop(1))
from fm_record_io import RecordError, canonical, read_regular, safe_path

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=('identity', 'publish', 'load'))
parser.add_argument('path', type=Path)
parser.add_argument('values', nargs='*')
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()

def identity(executable, state_file):
    # Remote-server mode has no Kit state file; its executable is the host's own.
    if not executable.is_absolute():
        raise RecordError('invalid managed executable root')
    if state_file:
        root = Path(state_file).parent
        if not root.is_absolute() or root.is_symlink():
            raise RecordError('invalid managed executable root')
        safe_path(root, executable)
    info = executable.stat()
    if not stat.S_ISREG(info.st_mode) or not os.access(str(executable), os.X_OK):
        raise RecordError('managed executable is missing or not executable')
    # jq transports these fields; decimal strings preserve every identity bit.
    return dict(path=str(executable.resolve()), device=str(info.st_dev), inode=str(info.st_ino),
                mtime_ns=str(info.st_mtime_ns), size=str(info.st_size))

def private_parent(path, create=False):
    if create:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RecordError('unsafe preflight record directory')

def read_private(path):
    private_parent(path)
    raw, _ = read_regular(path, 131072)
    info = path.lstat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RecordError('preflight record must be owner-only')
    return json.loads(raw)

def capabilities(value):
    return (isinstance(value, dict) and value.get('env') is True
            and type(value.get('claude_account_enforcement')) is bool)

def write_private(path, value):
    raw = canonical(value).encode()
    if len(raw) > 131072:
        raise RecordError('preflight record exceeds byte limit')
    if args.dry_run:
        print(str(path))
        return
    private_parent(path, create=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(raw)

try:
    if args.action == 'identity':
        state_file, = args.values
        result = identity(args.path, state_file)
    elif args.action == 'publish':
        handoff, = args.values
        result = json.loads(handoff)
        if result['identity'] != identity(Path(result['executable']), result['state_file']):
            raise RecordError('managed executable changed during preflight')
        write_private(args.path, result)
        sys.exit(0)
    else:
        result = read_private(args.path)
        gen, meta, harness, selector = args.values
        selector = selector if harness == 'claude' else ''
        raw, _ = read_regular(Path(meta), 131072)
        generations = [line for line in raw.decode().splitlines() if line.startswith('spawn_gen=')]
        if (generations != ['spawn_gen=' + gen] or 'omnigent_retired_gen=' + gen in raw.decode().splitlines()
                or result.get('generation') != gen or result.get('harness') != harness
                or result.get('selector') != selector or result.get('schema') != 1
                or not capabilities(result.get('capabilities'))):
            raise RecordError('preflight handoff does not name this launch')
        host = result.get('host', '')
        if host:
            if (not isinstance(host, str) or not re.fullmatch(r'[a-f0-9]{32}', host)
                    or result['state_file'] != ''
                    or not re.fullmatch(r'https://[A-Za-z0-9.-]+(:[0-9]+)?/?', result['server'])):
                raise RecordError('invalid preflight remote server')
        elif not re.fullmatch(r'http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/?', result['server']):
            raise RecordError('invalid preflight server')
        environment = result['client_environment']
        if not isinstance(environment, dict) or not (environment or host) or not all(
                re.fullmatch(r'(OMNIGENT_|OTEL_)[A-Z0-9_]+', key)
                and isinstance(value, str) and not re.search(r'[\x00-\x1f\x7f]', value)
                for key, value in environment.items()):
            raise RecordError('invalid preflight client environment')
        if not re.fullmatch(r'([a-z0-9]+(-[a-z0-9]+)*)?', result['account']):
            raise RecordError('invalid preflight account')
        if result['identity'] != identity(Path(result['executable']), result['state_file']):
            raise RecordError('managed executable identity changed after preflight')
        if not args.dry_run:
            args.path.unlink()
    sys.stdout.write(canonical(result))
except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
    print('preflight record: {}'.format(error), file=sys.stderr)
    sys.exit(1)
PY
}

# Managed-executable admission remains resolve_service's responsibility. This
# boundary owns only capability-cache keys and private record persistence.
capability_record() { # <load|save> <cache-path> <executable> <harness> [JSON]
  python3 -I -S - "$SCRIPT_DIR" "$@" <<'PY'
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
sys.path.insert(0, sys.argv.pop(1))
from fm_record_io import RecordError, canonical, read_regular

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=('load', 'save'))
parser.add_argument('path', type=Path)
parser.add_argument('executable', type=Path)
parser.add_argument('harness')
parser.add_argument('payload', nargs='?')
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()

def valid_flags(value):
    return (isinstance(value, dict) and value.get('env') is True
            and type(value.get('claude_account_enforcement')) is bool)

try:
    info = args.executable.stat()
    key = [str(args.executable.resolve()), str(info.st_ino), str(info.st_mtime_ns)]
    if not args.path.is_absolute():
        raise RecordError('capability cache requires an absolute state path')
    result = dict(schema=1, key=key, harness=args.harness, capabilities=None)
    if args.action == 'load':
        try:
            parent = args.path.parent.lstat()
            if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
                raise RecordError('unsafe capability cache directory')
            raw, _ = read_regular(args.path, 16384)
            saved_info = args.path.lstat()
            if saved_info.st_uid != os.getuid() or saved_info.st_mode & 0o077:
                raise RecordError('capability cache must be owner-only')
            saved = json.loads(raw)
            if (type(saved.get('schema')) is int and saved['schema'] == 1
                    and saved.get('key') == key and saved.get('harness') == args.harness
                    and valid_flags(saved.get('capabilities'))):
                result['capabilities'] = saved['capabilities']
        except (OSError, ValueError, TypeError, AttributeError):
            pass  # Only a new probe can authorize capability support on a miss.
        sys.stdout.write(canonical(result))
    else:
        result = json.loads(args.payload)
        if (result.get('key') != key or result.get('harness') != args.harness
                or not valid_flags(result.get('capabilities'))):
            raise RecordError('executable identity changed during capability probe')
        raw = canonical(result).encode()
        if len(raw) > 16384:
            raise RecordError('capability cache exceeds byte limit')
        if args.dry_run:
            print(str(args.path))
            sys.exit(0)
        args.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        parent = args.path.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            raise RecordError('unsafe capability cache directory')
        if args.path.exists() or args.path.is_symlink():
            previous = args.path.lstat()
            if not stat.S_ISREG(previous.st_mode) or previous.st_uid != os.getuid():
                raise RecordError('unsafe capability cache file')
        fd, temporary = tempfile.mkstemp(prefix='.omnigent-capabilities.', dir=str(args.path.parent))
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(raw)
            os.replace(temporary, str(args.path))
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
    print('capability cache: {}'.format(error), file=sys.stderr)
    sys.exit(1)
PY
}

check_health() {
  local health
  health=$(preflight_stage health 5 curl --silent --show-error --fail --max-time 5 "${SERVER%/}/health") || fail "server is unreachable: $SERVER"
  printf '%s' "$health" | jq -e '.status == "ok"' >/dev/null 2>&1 || fail "server health failed: $SERVER"
}

# Read FM_OMNIGENT_SERVER/FM_OMNIGENT_HOST into REMOTE_SERVER/REMOTE_HOST.
# Both empty selects the local Kit; a partial or malformed pair refuses.
remote_binding() {
  REMOTE_SERVER=${FM_OMNIGENT_SERVER:-}
  REMOTE_HOST=${FM_OMNIGENT_HOST:-}
  [ -n "$REMOTE_SERVER$REMOTE_HOST" ] || return 0
  [ -n "$REMOTE_SERVER" ] && [ -n "$REMOTE_HOST" ] \
    || fail 'a remote Omnigent binding needs both a server and a registered host id'
  [[ "$REMOTE_SERVER" =~ $REMOTE_SERVER_RE ]] || fail "invalid remote Omnigent server, expected an https origin: $REMOTE_SERVER"
  [[ "$REMOTE_HOST" =~ $HOST_ID_RE ]] || fail "invalid registered Omnigent host id: $REMOTE_HOST"
  REMOTE_SERVER=${REMOTE_SERVER%/}
}

binding_op() { # [task meta]
  local key
  [ "$#" -le 1 ] || fail 'binding takes at most one task record'
  if [ -z "${FM_OMNIGENT_SERVER:-}${FM_OMNIGENT_HOST:-}" ] && [ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ]; then
    for key in server host; do
      printf -v "FM_OMNIGENT_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" '%s' \
        "$(awk -F= -v key="omnigent_remote_$key" '$1 == key { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$1")"
    done
  fi
  remote_binding
  [ -z "$REMOTE_SERVER" ] || printf 'server=%s\nhost=%s\n' "$REMOTE_SERVER" "$REMOTE_HOST"
}

# Kit mode: the local service's status and readiness reports select the server,
# its client environment and the managed runtime executable.
resolve_kit_runtime() {
  local reason status_rc=0 readiness_rc=0
  command -v agent-kit >/dev/null 2>&1 || fail 'agent-kit is required on this host'
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
  # Readiness has no stage cap of its own: it may use whatever the shared
  # budget leaves, since the later stages fail anyway once that is spent.
  readiness=$(preflight_stage readiness "$budget" agent-kit observe serve status --readiness --json < /dev/null | head -c 131073) || readiness_rc=$?
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
  CLIENT_ENV_JSON=$(printf '%s' "$status" | jq -c .client_environment)
  # Retain fork provenance; capability support survives upgrades without a
  # commit allowlist.
  PROVENANCE=0
  if printf '%s' "$status" | jq -e '
    .omnigent.repository == "https://github.com/davidtandoh/omnigent.git"
  ' >/dev/null 2>&1; then PROVENANCE=1; fi
}

# Remote-server mode: no Kit runs here. This host's own Omnigent install
# launches against the parent's server, after this host proves it is the
# registered host. There is no Kit status to attest fork provenance, so the
# executable's own capability section alone decides account enforcement.
resolve_remote_runtime() {
  local found python identity_host
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required on this host'
  found=$(command -v omnigent) || fail "omnigent is required on this host to launch through $REMOTE_SERVER"
  OMNIGENT_BIN=$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$found") \
    || fail "cannot resolve the omnigent executable: $found"
  [ -f "$OMNIGENT_BIN" ] && [ -x "$OMNIGENT_BIN" ] || fail "omnigent is not an executable file: $OMNIGENT_BIN"
  python="${OMNIGENT_BIN%/*}/python"
  [ -x "$python" ] || fail "no Omnigent runtime Python beside $OMNIGENT_BIN"
  SERVER=$REMOTE_SERVER HOST_ID=$REMOTE_HOST STATE_FILE='' CLIENT_ENV_JSON='{}' PROVENANCE=1
  identity_host=$(preflight_stage identity 10 "$python" -I -c '
import sys
try:
    from omnigent.host.identity import load_host_identity_if_present
    identity = load_host_identity_if_present()
    print(identity.host_id.replace("-", "").lower() if identity is not None else "")
except Exception as error:
    sys.exit(f"host identity lookup failed: {type(error).__name__}")
' < /dev/null) || fail "cannot read this host's Omnigent host identity"
  [ -n "$identity_host" ] \
    || fail "this host has no Omnigent host identity; connect it with: omnigent host --server $SERVER --background"
  [ "$identity_host" = "$HOST_ID" ] \
    || fail "this host's Omnigent identity $identity_host is not the registered host $HOST_ID"
}

# The parent's server must list the registered host as online. One bounded GET.
check_host() {
  local body code rc=0 verdict='' state
  body=$(mktemp "${TMPDIR:-/tmp}/fm-omnigent-host.XXXXXX") || fail 'cannot stage the registered host check'
  code=$(preflight_stage host 5 curl --silent --max-time 5 --max-filesize 131072 --proto '=https' \
    --output "$body" --write-out '%{http_code}' "$SERVER/v1/hosts/$HOST_ID") || rc=$?
  if [ "$rc" != 0 ]; then
    verdict="cannot reach $SERVER to confirm registered Omnigent host $HOST_ID"
  elif [ "$code" = 404 ]; then
    verdict="Omnigent host $HOST_ID is not registered on $SERVER; connect it with: omnigent host --server $SERVER --background"
  elif [ "$code" != 200 ] || ! jq -e --arg id "$HOST_ID" \
    '.host_id | type == "string" and (ascii_downcase | gsub("-"; "")) == $id' "$body" >/dev/null 2>&1; then
    verdict="cannot confirm registered Omnigent host $HOST_ID on $SERVER (HTTP $code)"
  else
    state=$(jq -r '.status | tostring | .[0:40] | gsub("[^A-Za-z0-9_-]"; "")' "$body" 2>/dev/null) || state=unknown
    [ "$state" = online ] \
      || verdict="registered Omnigent host $HOST_ID is ${state:-unknown} on $SERVER; restart it with: omnigent host --server $SERVER --background"
  fi
  rm -f -- "$body"
  [ -z "$verdict" ] || fail "$verdict"
}

resolve_service() {
  local status readiness help identity flags cache cached handoff='' handoff_path='' budget=50
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    budget=${FM_TEST_OMNIGENT_PREFLIGHT_BUDGET:-50}
    case "$budget" in ''|*[!0-9]*) fail 'invalid test preflight budget' ;; esac
    [ "$budget" -ge 1 ] && [ "$budget" -le 50 ] || fail 'invalid test preflight budget'
  fi
  PREFLIGHT_STARTED=$(fm_timing_now_ms)
  PREFLIGHT_DEADLINE=$(( PREFLIGHT_STARTED + budget * 1000 ))
  case "$HARNESS" in claude|codex|kiro|agy) ;; *) fail "unverified wrapped harness: $HARNESS" ;; esac
  command -v jq >/dev/null 2>&1 || fail 'jq is required on this host'
  command -v curl >/dev/null 2>&1 || fail 'curl is required on this host'
  remote_binding
  HOST_ID=
  if [ -n "$REMOTE_SERVER" ]; then resolve_remote_runtime; else resolve_kit_runtime; fi
  identity=$(preflight_record identity "$OMNIGENT_BIN" "$STATE_FILE") || fail 'invalid managed executable identity'
  cache="${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-${SCRIPT_DIR%/bin}}}/state}/.omnigent-capabilities-$HARNESS.json"
  cached=$(capability_record load "$cache" "$OMNIGENT_BIN" "$HARNESS") || fail 'cannot identify the managed executable for capability caching'
  flags=$(printf '%s' "$cached" | jq -c .capabilities)
  if [ "$flags" = null ]; then
    help=$(preflight_stage capability "$budget" "$OMNIGENT_BIN" "$HARNESS" --help < /dev/null) || fail "$HARNESS capability probe failed"
    case "$help" in *'--env KEY=VALUE'*) ;; *) fail "$OMNIGENT_BIN lacks the native --env interface for $HARNESS" ;; esac
    flags=false
    if printf '%s\n' "$help" | awk '
      /^[[:space:]]*Capabilities:[[:space:]]*$/ { section = 1; next }
      /^[^[:space:]]/ { section = 0 }
      section && /^[[:space:]]+claude-account-enforcement([[:space:]]|$)/ { found = 1 }
      END { exit !found }
    '; then flags=true; fi
    cached=$(printf '%s' "$cached" | jq -c --argjson enforcement "$flags" \
      '.capabilities={env:true,claude_account_enforcement:$enforcement}')
    flags=$(printf '%s' "$cached" | jq -c .capabilities)
    if [ "$DRY_RUN" = 0 ]; then
      capability_record save "$cache" "$OMNIGENT_BIN" "$HARNESS" "$cached" || fail 'cannot save capability cache'
    fi
  fi
  check_health
  [ -z "$HOST_ID" ] || check_host
  CLAUDE_ACCOUNT_ENFORCEMENT=0
  # Only an exact entry in the help's capability section counts.
  if [ "$PROVENANCE" = 1 ] && [ "$(printf '%s' "$flags" | jq -r .claude_account_enforcement)" = true ]; then
    CLAUDE_ACCOUNT_ENFORCEMENT=1
  fi
  if [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_ACCOUNT_ENFORCEMENT" != 1 ]; then
    fail 'running daemon lacks verified exact Claude account enforcement; choose another worker or update Omnigent before selecting this account'
  fi
  CLIENT_ENV=()
  while IFS= read -r entry; do CLIENT_ENV+=("$entry"); done < <(printf '%s' "$CLIENT_ENV_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  # The runner refuses a session created without --account when the selected
  # folder belongs to a configured account, so ask the pinned runtime the same
  # question its runner asks. Only the account name leaves the lookup.
  CLAUDE_ACCOUNT=
  if [ "$HARNESS" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_ACCOUNT=$(preflight_stage account 10 env ${CLIENT_ENV[@]+"${CLIENT_ENV[@]}"} "${OMNIGENT_BIN%/*}/python" -I -c '
import sys
try:
    from omnigent.config import load_global_config
    from omnigent.onboarding.claude_accounts import account_name_for_config_dir
    print(account_name_for_config_dir(load_global_config(), sys.argv[1]) or "")
except Exception as error:
    sys.exit(f"account lookup failed: {type(error).__name__}")
' "$CLAUDE_CONFIG_DIR" < /dev/null) || fail 'cannot resolve the Omnigent account for the selected Claude login'
    [[ "$CLAUDE_ACCOUNT" =~ ^([a-z0-9]+(-[a-z0-9]+)*)?$ ]] || fail 'invalid Omnigent account name for the selected Claude login'
  fi
  if [ "$OP" = check ] && [ -n "${FM_OMNIGENT_PREFLIGHT:-}" ]; then
    [[ "${FM_OMNIGENT_RECORD_GEN:-}" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'missing preflight spawn generation'
    handoff_path=$FM_OMNIGENT_PREFLIGHT
    handoff=$(jq -cn --arg generation "$FM_OMNIGENT_RECORD_GEN" --arg harness "$HARNESS" \
      --arg selector "${CLAUDE_CONFIG_DIR:-}" --arg executable "$OMNIGENT_BIN" --arg server "$SERVER" \
      --arg state_file "$STATE_FILE" --arg account "$CLAUDE_ACCOUNT" --argjson identity "$identity" \
      --argjson enforcement "$CLAUDE_ACCOUNT_ENFORCEMENT" --argjson client "$CLIENT_ENV_JSON" --arg host "$HOST_ID" \
      '{schema:1,generation:$generation,harness:$harness,
        selector:(if $harness == "claude" then $selector else "" end),
        executable:$executable,server:$server,state_file:$state_file,account:$account,identity:$identity,
        client_environment:$client,capabilities:{env:true,claude_account_enforcement:($enforcement == 1)}}
        + (if $host == "" then {} else {host:$host} end)')
    preflight_record publish "$handoff_path" "$handoff" || fail 'cannot publish verified preflight handoff'
  fi
  fm_timing_record omnigent-preflight total "$PREFLIGHT_STARTED" passed
  PREFLIGHT_STARTED=
}

OP=${1:---help}
shift || true
case "$OP" in
  _title-session) title_session "$@"; exit ;;
  archive) archive_session "$@"; exit ;;
  capture) capture_session "$@"; exit ;;
  probe) probe_session "$@"; exit ;;
  approvals) approvals_session "$@"; exit ;;
  binding) binding_op "$@"; exit ;;
  stop-attach) [ "$#" -eq 1 ] || fail 'stop-attach requires one task record'; stop_attach "$1"; exit ;;
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
if [ "$OP" = run ] && [ -n "${FM_OMNIGENT_PREFLIGHT:-}" ]; then
  PREFLIGHT_STARTED=$(fm_timing_now_ms)
  PREFLIGHT_DEADLINE=$((PREFLIGHT_STARTED + 10000))
  saved=$(preflight_record load "$FM_OMNIGENT_PREFLIGHT" "${FM_OMNIGENT_RECORD_GEN:-}" \
    "${FM_OMNIGENT_RECORD_META:-}" "$HARNESS" "${CLAUDE_CONFIG_DIR:-}") || fail 'invalid preflight handoff'
  SERVER=$(printf '%s' "$saved" | jq -r .server)
  STATE_FILE=$(printf '%s' "$saved" | jq -r .state_file)
  HOST_ID=$(printf '%s' "$saved" | jq -r '.host // ""')
  OMNIGENT_BIN=$(printf '%s' "$saved" | jq -r .executable)
  CLAUDE_ACCOUNT=$(printf '%s' "$saved" | jq -r .account)
  CLAUDE_ACCOUNT_ENFORCEMENT=$(printf '%s' "$saved" | jq -r 'if .capabilities.claude_account_enforcement then 1 else 0 end')
  CLIENT_ENV=()
  while IFS= read -r entry; do CLIENT_ENV+=("$entry"); done < <(printf '%s' "$saved" | jq -r '.client_environment | to_entries[] | "\(.key)=\(.value)"')
  check_health
  fm_timing_record omnigent-preflight total "$PREFLIGHT_STARTED" passed
  PREFLIGHT_STARTED=
else
  resolve_service
fi
[ "$OP" != check ] || exit 0
ARGS=("$HARNESS" --server "$SERVER")
[ "$HARNESS" != claude ] || ARGS+=(--use-native-config)
# These names belong to Firstmate's existing launch contract. Never forward
# arbitrary ambient provider credentials, HOME, or the Omnigent-owned CODEX_HOME.
ENV_NAMES='FM_FRESH_TOKEN FM_OMNIGENT FM_BACKEND FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_TRACE_CONTEXT FM_SUPERVISION_MODEL FM_TASK_ID FM_TASK_INBOX COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST TRACEPARENT GOTMPDIR TMPDIR PATH CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CODE_SEND_FEEDBACK KIRO_HOME HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET_PATH'
export FM_OMNIGENT=on
# A remote second mate's own workers launch through the same server and host,
# and the title observer verifies the session's host from this binding.
# Local launches forward exactly what they did before this binding existed.
if [ -n "$HOST_ID" ]; then
  export FM_OMNIGENT_SERVER="${SERVER%/}" FM_OMNIGENT_HOST="$HOST_ID"
  ENV_NAMES="$ENV_NAMES FM_OMNIGENT_SERVER FM_OMNIGENT_HOST"
else
  unset FM_OMNIGENT_SERVER FM_OMNIGENT_HOST
fi
for name in $ENV_NAMES; do
  case "$name" in
    # Claude treats an empty selector as the current directory. Omit it so
    # the default account uses ~/.claude; preserve non-empty selectors verbatim.
    # A folder owned by a configured Omnigent account selects it by name
    # instead; Omnigent refuses --account together with this variable.
    CLAUDE_CONFIG_DIR) if [ "$HARNESS" = claude ]; then
      if [ -n "$CLAUDE_ACCOUNT" ]; then ARGS+=(--account "$CLAUDE_ACCOUNT")
      elif [ "$CLAUDE_ACCOUNT_ENFORCEMENT" = 1 ] && [ -n "${!name:-}" ]; then ARGS+=(--env "$name=${!name}"); fi
    elif [ -n "${!name:-}" ]; then ARGS+=(--env "$name=${!name}"); fi ;;
    # These owners treat empty as unset. Explicit empties also prevent stale
    # daemon routing or trace state from reappearing in a fresh native session.
    FM_*|HERDR_*|TRACEPARENT) ARGS+=(--env "$name=${!name-}") ;;
    *) if [ "${!name+x}" = x ]; then ARGS+=(--env "$name=${!name}"); fi ;;
  esac
done
# Git reads GIT_CONFIG_KEY_n/VALUE_n for every n below GIT_CONFIG_COUNT and
# refuses to run when one is missing. A relaunch in a retained pane appends a
# second entry, so forward the complete set the count names, or none of it.
git_config_env=()
if [ "${GIT_CONFIG_COUNT+x}" = x ] && [[ "$GIT_CONFIG_COUNT" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
  git_config_env=(--env "GIT_CONFIG_COUNT=$GIT_CONFIG_COUNT")
  for ((index = 0; index < GIT_CONFIG_COUNT; index++)); do
    key_name=GIT_CONFIG_KEY_$index value_name=GIT_CONFIG_VALUE_$index
    if [ "${!key_name+x}" != x ] || [ "${!value_name+x}" != x ]; then git_config_env=(); break; fi
    git_config_env+=(--env "$key_name=${!key_name}" --env "$value_name=${!value_name}")
  done
fi
ARGS+=("${git_config_env[@]+${git_config_env[@]}}")
for name in CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS FM_OMP_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI; do
  ARGS+=(--env "$name=")
done
if [ "$DRY_RUN" = 1 ]; then
  jq -n --arg executable "$OMNIGENT_BIN" --arg state_file "$STATE_FILE" --arg server_url "$SERVER" --arg harness "$HARNESS" \
    --arg host "$HOST_ID" \
    '{executable:$executable,harness:$harness,server_url:$server_url,state_file:$state_file}
      + (if $host == "" then {} else {host_id:$host} end)'
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
export FM_OMNIGENT_ATTACH_PID=$$
FM_OMNIGENT_ATTACH_START=$(fm_pid_start_time "$$") || fail 'cannot identify attach process'
export FM_OMNIGENT_ATTACH_START
# Keep the native wrapper as the foreground exec owner. Only its diagnostic
# stderr enters the invocation-private reader; terminal attach/stdin/stdout,
# signals and native exit status retain the existing transport owner.
exec env ${CLIENT_ENV[@]+"${CLIENT_ENV[@]}"} LC_ALL="$client_locale" "$OMNIGENT_BIN" "${ARGS[@]}" -- "${REST[@]+${REST[@]}}" \
  2> >(python3 "$SCRIPT_DIR/fm-omnigent-title.py" --server "$SERVER" --harness "$HARNESS" \
    --title "$TITLE" --started "$TITLE_STARTED" --launcher "$SCRIPT_DIR/fm-omnigent.sh")
