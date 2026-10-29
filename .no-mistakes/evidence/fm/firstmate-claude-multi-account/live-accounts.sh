#!/usr/bin/env bash
set -u
. bin/fm-claude-accounts-lib.sh
export FM_CONFIG_OVERRIDE="$PWD/.validation-absent-config"
failed=0
for selector in '~/.claude_b' "$HOME/.claude_b/" './relative-profile/' ; do
  out=$(CLAUDE_CONFIG_DIR="$selector" bash bin/fm-claude-accounts.sh --dry-run --project "$PWD" --model sonnet)
  rc=$?
  printf 'explicit preview selector=%s exit=%s\n%s\n' "$selector" "$rc" "$out"
  [ "$rc" = 0 ] && [ "$out" = "$(printf 'account: explicit\nconfig_dir: %s' "$selector")" ] || failed=1
done
for lane in claude-home claude-guidex; do
  root=''
  [ "$lane" != claude-guidex ] || root="$HOME/.claude_b"
  if fm_worker_account_check claude "$lane" "$root" "$(command -v claude)" '' 'live status-only validation' 2>/dev/null; then
    printf 'real Claude status-only check: %s signed_in=true\n' "$lane"
  else
    printf 'real Claude status-only check: %s signed_in=false\n' "$lane"
    failed=1
  fi
done
for project in "$PWD" "$HOME/workspace/guidex"; do
  out=$(CLAUDE_CONFIG_DIR='' fm_claude_spawn_root "$project" "$PWD/projects" sonnet "$(command -v claude)")
  rc=$?
  printf 'real non-Fable routing project=%s exit=%s config_dir=%s\n' "$project" "$rc" "${out:-unset (personal)}"
  [ "$rc" = 0 ] || failed=1
done
printf 'real account reporter:\n'
bash bin/fm-claude-accounts.sh
rc=$?
printf 'account_reporter_exit=%s\n' "$rc"
[ "$rc" = 0 ] || failed=1
exit "$failed"
