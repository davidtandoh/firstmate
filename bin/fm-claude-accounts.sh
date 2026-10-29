#!/usr/bin/env bash
# Report the two local Claude account rows, or preview a task account choice.
# Usage: fm-claude-accounts.sh [--json] [--snapshot <quota.json>]
#        fm-claude-accounts.sh --dry-run --project <path|projects/name> --model <id> [--snapshot <quota.json>] [--claude-floor <JSON>]
# --claude-floor supplies the selected profile floor for --dry-run.
# --dry-run reads quota and prints the account and Claude configuration selector;
# it never launches a worker, changes login, or writes configuration.
# --snapshot uses captured quota without contacting quota-axi.
# Exit 1 means unavailable or unknown Fable allowance; use the remaining
# dispatch profiles. The home account pin wins, then an explicit
# CLAUDE_CONFIG_DIR, then automatic routing.
# bin/fm-claude-accounts-lib.sh owns account collection and binding.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-claude-accounts-lib.sh
. "$SCRIPT_DIR/fm-claude-accounts-lib.sh"
snapshot_path='' project='' model='' json=0 dry_run=0 floor=null floor_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --snapshot|--project|--model|--claude-floor)
      [ "$#" -ge 2 ] || { echo 'error: option needs a value' >&2; exit 2; }
      case "$1" in --snapshot) snapshot_path=$2 ;; --project) project=$2 ;; --model) model=$2 ;; --claude-floor) floor=$2; floor_set=1 ;; esac
      shift 2 ;;
    --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
    *) echo 'error: unknown argument' >&2; exit 2 ;;
  esac
done
if [ "$floor_set" = 1 ] && [ "$dry_run" != 1 ]; then
  echo 'error: --claude-floor requires --dry-run' >&2
  exit 2
fi
floor=$(fm_claude_floor_json "$floor") || { echo 'error: invalid --claude-floor' >&2; exit 2; }
if [ "$dry_run" = 1 ]; then
  [ -n "$project" ] && [ -n "$model" ] || { echo 'error: --dry-run requires --project and --model' >&2; exit 2; }
  selection=$(fm_worker_account_resolve claude "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$SCRIPT_DIR/..}/config}" 'config/claude-account') || exit 1
  if [ -n "$selection" ]; then
    declared=${selection%%$'\t'*}
    selector=${selection#*$'\t'}
    selector=${selector%%$'\t'*}
    if [ "$declared" = ordinary ]; then
      printf 'account: claude-home\nconfig_dir: unset (personal)\n'
    else
      printf 'account: %s\nconfig_dir: %s\n' "$(fm_claude_explicit_lane "$selector")" "$selector"
    fi
    exit 0
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    selector=$CLAUDE_CONFIG_DIR
    printf 'account: explicit\nconfig_dir: %s\n' "$selector"
    exit 0
  fi
  guidex_root=$(fm_claude_guidex_root) || exit 1
  if [ -z "$guidex_root" ]; then
    printf 'account: ambient\nconfig_dir: unchanged (routing unconfigured)\n'
    exit 0
  fi
fi
if [ -n "$snapshot_path" ]; then
  [ -f "$snapshot_path" ] && [ ! -L "$snapshot_path" ] || { echo 'error: snapshot must be a regular file' >&2; exit 2; }
  snapshot=$(cat "$snapshot_path")
else
  snapshot=$(fm_quota_snapshot) || { echo 'error: account quota collection failed' >&2; exit 1; }
fi
printf '%s\n' "$snapshot" | fm_quota_json_valid || { echo 'error: invalid quota snapshot' >&2; exit 2; }
if [ "$dry_run" = 1 ]; then
  repo=$(fm_claude_repo_lane "$project" "${FM_PROJECTS_OVERRIDE:-${FM_HOME:-$SCRIPT_DIR/..}/projects}")
  lane=$(fm_claude_account_lane "$snapshot" "$model" "$repo" "$floor")
  case "$lane" in
    claude-home) printf 'account: claude-home\nconfig_dir: unset (personal)\n' ;;
    claude-guidex) printf 'account: claude-guidex\nconfig_dir: %s\n' "$guidex_root" ;;
    *) printf 'account: %s\n' "${lane:-unknown}"; exit 1 ;;
  esac
elif [ "$json" = 1 ]; then
  printf '%s\n' "$snapshot"
else
  jq -r "$FM_QUOTA_ROW_JQ"'
    .providers[] | select(.provider == "claude") |
    "\(.accountKey // "default") status=\(.state.status // "unknown") Fable weekly remaining=\(claude_fable_weekly(.) // "unknown")% used=\(claude_fable_weekly(.) as $remaining | if $remaining == null then "unknown" else 100 - $remaining end)%",
    (.quotaSemantics.effectiveAvailability[]? | "  \(.scope) remaining=\(.effectivePercentRemaining // "unknown")%")' <<< "$snapshot"
fi
