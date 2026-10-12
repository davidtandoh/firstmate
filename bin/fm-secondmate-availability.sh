#!/usr/bin/env bash
# fm-secondmate-availability.sh - decide whether work routed by scope to a
# registered second mate can go there right now.
#
# Usage:
#   fm-secondmate-availability.sh <secondmate-id> [portable|host-bound]
#
# Scope still decides which second mate fits the work (AGENTS.md section 7).
# This command answers only the follow-up question for a remote route whose
# data/secondmates.md entry carries `availability: when-online`, such as a
# laptop that sleeps: is it reachable now? Every other route is always-on and
# is answered without any probe, so existing second mates route as before.
#
# For a when-online route it runs the same bounded, read-only remote state
# probe as the watcher's liveness tick (bin/fm-secondmate-liveness-lib.sh poll
# mode: one fm-on.sh state call within FM_SECONDMATE_LIVENESS_PROBE_TIMEOUT,
# default 5 seconds). Only an `alive` reply makes the route available. An
# unreachable or sleeping host, a timeout, an inconclusive state, or an
# endpoint that is not running all read as unavailable. The probe never
# relaunches, repairs, or records anything; liveness recovery stays the
# watcher's job.
#
# Prints exactly one decision line:
#   route <id>: <why>   route the work to the second mate (exit 0)
#   local <id>: <why>   unavailable; run the portable work in this home (exit 1)
#   queue <id>: <why>   unavailable; keep the host-bound work queued here with
#                       this reason (exit 1)
# The work kind defaults to portable. Usage or registry errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
ID=$1
KIND=${2:-portable}
case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$KIND" in portable|host-bound) ;; *) usage ;; esac
secondmate_registry_line_for_id "$REG" "$ID" \
  || die "no single well-formed registry entry for secondmate $ID in $REG"

if [ "$SECONDMATE_REGISTRY_AVAILABILITY" != when-online ]; then
  printf 'route %s: always-on route; no availability probe needed\n' "$ID"
  exit 0
fi

HOST=$SECONDMATE_REGISTRY_HOST
META="$STATE/$ID.meta"
if [ -z "$(fm_meta_get "$META" remote_host)" ]; then
  REASON="no running remote endpoint is recorded for $ID"
else
  fm_secondmate_liveness_probe "$META" "$ID" poll
  case "$FM_SM_LIVE_STATUS" in
    alive)
      printf 'route %s: host %s reachable and second mate live\n' "$ID" "$HOST"
      exit 0
      ;;
    relaunchable) REASON="host $HOST reachable but the second mate endpoint is $FM_SM_LIVE_STATE until liveness recovery relaunches it" ;;
    silent) REASON="no running remote endpoint is recorded for $ID" ;;
    *) REASON=${FM_SM_LIVE_REASON:-remote endpoint state unknown on $HOST} ;;
  esac
fi

if [ "$KIND" = host-bound ]; then
  printf 'queue %s: %s; keep host-bound work queued until %s is reachable\n' "$ID" "$REASON" "$HOST"
else
  printf 'local %s: %s; run portable work in this home\n' "$ID" "$REASON"
fi
exit 1
