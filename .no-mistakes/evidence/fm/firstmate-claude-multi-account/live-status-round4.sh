#!/usr/bin/env bash
set -euo pipefail
. bin/fm-worker-account-lib.sh
printf 'Installed Claude: '
claude --version
for lane in personal guidex; do
  root=''
  [ "$lane" != guidex ] || root="$HOME/.claude_b"
  if fm_worker_account_check claude "$lane" "$root" "$(command -v claude)" '' 'live validation status-only'; then
    printf '%s status: signed in\n' "$lane"
  else
    printf '%s status: unavailable to this process\n' "$lane"
  fi
done
printf '\nExplicit selector CLI preview (no account pin override):\n'
for selector in '~/.claude_b/' "$HOME/.claude_b/" './relative-claude/'; do
  output=$(CLAUDE_CONFIG_DIR="$selector" bin/fm-claude-accounts.sh --dry-run --project "$PWD" --model sonnet)
  printf '%s\n' "$output"
  [[ "$output" == *"config_dir: $selector"* ]] || exit 1
done
