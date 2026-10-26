#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# Line 1 of state/.lock is the owning session's anchor pid, resolved by
# fm_session_lock_anchor_pid in bin/fm-session-lock-lib.sh: the harness (agent)
# process found by walking the shell's ancestry, which lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. For a Claude session that proves a
# trusted session id the anchor is CLAUDE_PID, the model-loop process, so a
# shared transient daemon or a front-end that outlives the session never keeps
# a dead session's lock alive. On Windows that pid is recorded tagged, and a
# /clear re-key under the same tagged pid refreshes the sidecar as it does on
# POSIX. Line 1 keeps its whole-line pid format because every other reader
# takes the first line as the pid.
#
# The trusted id itself is recorded beside the lock in state/.lock-session, a
# sidecar written only here and only under the claim lock: refreshed on every
# confirmed-own acquisition, including the early already-mine exit that waits
# for the claim lock, removed when the acquiring session proves no trusted id,
# and left byte-identical when it already names that id. A same-session
# confirmation keeps a live line 1 that is in this session's harness ancestry,
# because bin/fm-startup-network.sh compares that pid across its deferred
# sweeps; a dead recorded pid is reclaimed and rewritten to this session's
# anchor. A live line 1 outside the ancestry, owned only through the trusted
# id, is rewritten to the anchor under the claim lock and then the
# lease-command lock, and task leases recorded against the old pid move to the
# anchor in that same section (fm_lease_rekey_holder in bin/fm-lease-lib.sh),
# as does a Claude auto-arm rewake bound to the old pid, under
# state/.claude-autoarm.lock (fm_autoarm_rekey_session in bin/fm-wake-lib.sh).
# A later /clear re-key in the same process is then still proven by ancestry
# after the id changes, a held lease stays live, and the mid-turn guard still
# accepts that rewake. A lease or rewake that cannot be moved, including when
# the auto-arm lock stays busy past LEASE_LOCK_WAIT seconds, is reported as a
# warning and the re-anchor still completes. When the lease-command
# lock stays busy past LEASE_LOCK_WAIT seconds, the confirmation only refreshes
# the sidecar, as for a line 1 in the ancestry, and a later acquisition
# re-anchors.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0.
#                             A held lock is not proof the holder is consuming
#                             wakes. Machine-readable lock fields live on
#                             fm-inbox.sh ready, from the same inspect helper.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness, trusted
# session id, anchor pid) is owned by the shared session-lock lib so the Claude
# Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free) echo "lock: free" ;;
    unreadable) echo "lock: unreadable" ;;
    held) echo "lock: held by live harness pid $FM_LOCK_INSPECT_PID" ;;
    unknown)
      # A live pid whose identity cannot be read is neither held nor stale.
      case "$FM_LOCK_INSPECT_PID:$FM_LOCK_INSPECT_LIVE_HARNESS" in
        [0-9]*:unknown) echo "lock: unreadable process evidence (pid $FM_LOCK_INSPECT_PID)" ;;
        *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
      esac
      ;;
    *) echo "lock: stale (pid $FM_LOCK_INSPECT_PID dead or not a harness)" ;;
  esac
  exit 0
fi

me=$(fm_session_lock_anchor_pid) || {
  if fm_win_boundary_applies; then
    # Here the parent link does not reach the harness at all, so "not in the
    # ancestry" would describe the wrong problem and send the reader hunting a
    # process tree that can never contain the answer.
    echo "error: cannot identify this harness session on Windows: it publishes no session pid this build recognizes (see FM_WIN_HARNESS_PID_VARS in bin/fm-session-lock-lib.sh; CLAUDE_PID is taken only together with CLAUDE_CODE_SESSION_ID); operate read-only until resolved" >&2
  else
    echo "error: cannot locate harness process in ancestry" >&2
  fi
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
LEASE_LOCK="$STATE/.fm-lease-command.lock"
LEASE_LOCK_HELD=0
LEASE_LOCK_WAIT=5
AUTOARM_LOCK="$STATE/.claude-autoarm.lock"
AUTOARM_LOCK_HELD=0
# The live line-1 pid a same-session confirmation is moving off, or empty.
REANCHOR=
# PHASE 0: committed/none. 1: sidecar mutated, line 1 not written. 2: line 1 written, not verified.
# KIND 0: no backup. 1: restore $LOCK_SESSION_PREV. 2: sidecar was absent.
LOCK_SESSION_PHASE=0
LOCK_SESSION_KIND=0
LOCK_SESSION_PREV="$STATE/.lock-session.prev"
LOCK_LINE_PRE=
release_autoarm_lock() {
  if [ "$AUTOARM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$AUTOARM_LOCK"
    AUTOARM_LOCK_HELD=0
  fi
}
release_lease_lock() {
  if [ "$LEASE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LEASE_LOCK"
    LEASE_LOCK_HELD=0
  fi
}
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
restore_uncommitted_lock_session() {
  case "$LOCK_SESSION_PHASE" in
    1)
      case "$LOCK_SESSION_KIND" in
        1) mv -f "$LOCK_SESSION_PREV" "$LOCK_SESSION" 2>/dev/null || true ;;
        2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
      esac
      ;;
    2) rm -f "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || true ;;
  esac
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
}
commit_lock_session() {
  LOCK_SESSION_PHASE=0
  LOCK_SESSION_KIND=0
  rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
}
on_lock_exit() {
  restore_uncommitted_lock_session
  [ -n "$LOCK_LINE_PRE" ] && rm -f "$LOCK_LINE_PRE"
  release_autoarm_lock
  release_lease_lock
  release_claim_lock
}
trap on_lock_exit EXIT
trap 'exit 1' HUP INT TERM

remember_lock_session() {
  [ "$LOCK_SESSION_PHASE" -eq 0 ] || return 0
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    rm -f "$LOCK_SESSION_PREV" 2>/dev/null || true
    cp -P "$LOCK_SESSION" "$LOCK_SESSION_PREV" 2>/dev/null || return 1
    LOCK_SESSION_KIND=1
  else
    LOCK_SESSION_KIND=2
  fi
  LOCK_SESSION_PHASE=1
}

# Record the trusted session id beside the lock, or remove a sidecar that no
# trusted id backs. Called only while the claim lock is held. A sidecar already
# naming this id is left untouched, so a same-session confirmation keeps it
# byte-identical.
publish_lock_session() {
  local trusted recorded tmp
  if trusted=$(fm_session_lock_trusted_session_id); then
    if recorded=$(fm_session_lock_recorded_session_id "$STATE") && [ "$recorded" = "$trusted" ]; then
      return 0
    fi
    remember_lock_session || return 1
    tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || return 1
    if ! { printf '%s\n' "$trusted" > "$tmp" && mv -f "$tmp" "$LOCK_SESSION"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 1
    fi
    return 0
  fi
  if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    remember_lock_session || return 1
    rm -f "$LOCK_SESSION" 2>/dev/null || return 1
  fi
  return 0
}

publish_lock_session_or_die() {
  publish_lock_session && return 0
  echo "error: cannot record the session identity beside the lock; operate read-only until resolved" >&2
  exit 1
}

# This session already holds the lock, recorded as pid $1. Line 1 stays exactly
# as recorded while that pid is alive and in this session's ancestry; only the
# sidecar is refreshed, under the claim lock, so a /clear re-key inside the same
# process replaces the old id. A live line 1 outside the ancestry is re-anchored
# as the header describes: REANCHOR records it and the caller keeps both locks
# for the guarded write below.
# A same-session confirmation waits for the claim lock so the sidecar refresh
# completes. After the wait, the lock is re-read and the sidecar is refreshed
# only when this session still owns it; otherwise the claim lock is released
# and the caller continues with the ordinary live-owner or reclaim path. The
# prior-session-sweep-is-finishing refusal is a takeover rule and does not
# apply here.
confirm_own_lock() {  # <recorded-pid>
  local recorded pids waited=0
  if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
    fm_lock_acquire_wait "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=1
    waited=1
  fi
  recorded=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$recorded" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    if [ "$recorded" != "$me" ] && pids=$(fm_harness_ancestry_pids) \
      && ! fm_harness_pid_listed "$recorded" "$pids" \
      && fm_lock_acquire_wait_max "$LEASE_LOCK" "$LEASE_LOCK_WAIT"; then
      LEASE_LOCK_HELD=1
      REANCHOR=$recorded
      return 0
    fi
    publish_lock_session_or_die
    commit_lock_session
    release_claim_lock
    echo "lock acquired: harness pid $recorded"
    exit 0
  fi
  if [ "$waited" -eq 1 ]; then
    release_claim_lock
  fi
  return 1
}

refuse_live_owner() {  # <recorded-pid>
  local recorded
  if recorded=$(fm_session_lock_recorded_session_id "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $1, session $recorded); operate read-only until resolved" >&2
  else
    echo "error: another live firstmate session holds the lock (pid $1); operate read-only until resolved" >&2
  fi
  exit 1
}

# fm_harness_pid_alive returns 2 when the recorded pid is alive but its
# identity cannot be read. That is not stale-owner evidence, so it must never
# reclaim the lock.
refuse_unreadable_owner() {  # <recorded-pid>
  echo "error: session-lock process evidence is unreadable (pid $1); operate read-only until resolved" >&2
  exit 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ] || fm_session_lock_owned_by_self "$STATE"; then
    confirm_own_lock "$old"
    old=$(cat "$LOCK" 2>/dev/null || true)
  fi
  if [ -z "$REANCHOR" ]; then
  fm_harness_pid_alive "$old"
  case "$?" in
    0) [ -n "${FM_FRESH_TOKEN:-}" ] || refuse_live_owner "$old" ;;
    2) refuse_unreadable_owner "$old" ;;
  esac
  fi
fi

if [ "$CLAIM_LOCK_HELD" -ne 1 ]; then
  if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
    sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
      echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
      exit 1
    fi
    fm_lock_acquire_wait "$CLAIM_LOCK"
  fi
  CLAIM_LOCK_HELD=1
fi

# A /fresh successor may replace only the specific live owner that issued its
# single-use token. This exception is checked again inside the ordinary claim
# mutex, so timeout revocation and simultaneous startups cannot both win.
fresh_takeover=0
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ -n "${FM_FRESH_TOKEN:-}" ] && fm_harness_pid_alive "$old"; then
    fresh_request="$STATE/.fresh-handoff"
    fresh_session=${HARNESS_CLAUDE_NATIVE_REQUEST_SESSION_ID:-}
    fresh_json=
    if [ -f "$fresh_request" ] && [ ! -L "$fresh_request" ]; then
      fresh_json=$(head -c 4097 "$fresh_request" 2>/dev/null || true)
    fi
    if [ ! -f "$fresh_request" ] || [ -L "$fresh_request" ] ||
      ! fm_session_lock_trusted_session_id >/dev/null ||
      ! [[ "$fresh_session" =~ ^[a-f0-9]{32}$ ]] ||
      ! [ "${#fresh_json}" -le 4096 ] ||
      ! printf '%s' "$fresh_json" | jq -se --arg token "$FM_FRESH_TOKEN" \
        --arg old "$(head -c 32 "$LOCK")" --arg session "$fresh_session" \
        --arg claude "$(fm_session_lock_trusted_session_id)" '
          length == 1 and (.[0] |
            .token == $token and .old_pid == $old and .old_session != $session and
            (.old_session | type == "string" and test("^[a-f0-9]{32}$")) and
            (.old_claude | type == "string" and length > 0) and .old_claude != $claude)
        ' >/dev/null 2>&1; then
      echo 'error: fresh-session handoff is invalid or revoked; operate read-only' >&2
      exit 1
    fi
    fresh_takeover=1
  fi
  if [ -z "$REANCHOR" ] && [ "$old" != "$me" ] && [ "$fresh_takeover" -eq 0 ]; then
    fm_harness_pid_alive "$old"
    case "$?" in
      0)
        fm_session_lock_owned_by_self "$STATE" && confirm_own_lock "$old"
        old=$(cat "$LOCK" 2>/dev/null || true)
        if [ "$old" != "$me" ]; then
          fm_harness_pid_alive "$old"
          case "$?" in
            0) refuse_live_owner "$old" ;;
            2) refuse_unreadable_owner "$old" ;;
          esac
        fi
        ;;
      2) refuse_unreadable_owner "$old" ;;
    esac
  fi
fi
if [ "$fresh_takeover" -eq 1 ]; then
  # Publish the receipt before changing ownership. The caller accepts it only
  # after line 1 also names this verified live anchor.
  fresh_receipt=$(mktemp "$STATE/.fresh-claimed.XXXXXX") || exit 1
  if (umask 077; jq -cn --arg token "$FM_FRESH_TOKEN" --arg pid "$me" --arg session "$fresh_session" \
    '{token:$token,pid:$pid,session:$session}' > "$fresh_receipt") && mv -f "$fresh_receipt" "$STATE/.fresh-claimed"; then
    :
  else
    rm -f "$fresh_receipt"
    exit 1
  fi
fi
# The sidecar goes first: a fresh pid beside a previous session's id would let
# that session's resume own this lock. If the sidecar changes before line 1 is
# written, a failure restores the previous sidecar. If line 1 is written but
# not yet verified, a failure removes the sidecar and leaves the lock
# ancestry-only. After line 1 verifies as this session's anchor, a later
# signal leaves the published pair in place, except on the re-anchor path:
# there a HUP, INT, or TERM during the lease move or the bounded
# .claude-autoarm.lock wait, before commit_lock_session, still runs
# restore_uncommitted_lock_session with phase 2 and removes the sidecar.
publish_lock_session_or_die
if [ -f "$LOCK" ]; then
  LOCK_LINE_PRE=$(mktemp "$STATE/.lock.pre.XXXXXX") || {
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  }
  if ! cp "$LOCK" "$LOCK_LINE_PRE" 2>/dev/null; then
    echo "error: cannot write session lock; operate read-only until resolved" >&2
    exit 1
  fi
fi
LOCK_SESSION_PHASE=2
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  lock_unchanged=0
  if [ -n "$LOCK_LINE_PRE" ] && cmp -s "$LOCK_LINE_PRE" "$LOCK"; then
    lock_unchanged=1
  elif [ -z "$LOCK_LINE_PRE" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    lock_unchanged=1
  fi
  if [ "$lock_unchanged" -eq 1 ]; then
    if [ "$LOCK_SESSION_KIND" -ne 0 ]; then
      LOCK_SESSION_PHASE=1
    else
      LOCK_SESSION_PHASE=0
    fi
  fi
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ -n "$REANCHOR" ] && ! fm_lease_rekey_holder "$REANCHOR" "$me"; then
  echo "warning: a task lease recorded against pid $REANCHOR could not be moved to pid $me, so it reads as stale" >&2
fi
if [ -n "$REANCHOR" ] && fm_autoarm_ledger_read "$STATE" && [ "$FM_AUTOARM_SESSION" = "$REANCHOR" ]; then
  if fm_lock_acquire_wait_max "$AUTOARM_LOCK" "$LEASE_LOCK_WAIT"; then
    AUTOARM_LOCK_HELD=1
  fi
  if [ "$AUTOARM_LOCK_HELD" -ne 1 ] || ! fm_autoarm_rekey_session "$STATE" "$REANCHOR" "$me"; then
    echo "warning: the Claude auto-arm rewake recorded against pid $REANCHOR could not be moved to pid $me, so a mid-turn guard can report supervision off until the next Stop" >&2
  fi
  release_autoarm_lock
fi
commit_lock_session
release_lease_lock
release_claim_lock
echo "lock acquired: harness pid $me"
