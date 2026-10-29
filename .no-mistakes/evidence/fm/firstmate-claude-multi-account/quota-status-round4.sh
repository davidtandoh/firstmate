#!/usr/bin/env bash
set -euo pipefail
. bin/fm-claude-accounts-lib.sh
quota-axi --version
clean=(env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR)
for variable in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do clean+=(-u "$variable"); done
for lane in personal guidex; do
  code=0
  if [ "$lane" = personal ]; then
    result=$(fm_run_timed 45 "${clean[@]}" quota-axi --provider claude --json --no-credential-refresh 2>/dev/null) || code=$?
  else
    result=$(fm_run_timed 45 "${clean[@]}" "CLAUDE_CONFIG_DIR=$HOME/.claude_b" quota-axi --provider claude --json --no-credential-refresh 2>/dev/null) || code=$?
  fi
  printf '%s quota exit: %s\n' "$lane" "$code"
  printf '%s\n' "$result" | jq -c '{schemaVersion,providers:[.providers[] | {provider,state:(.state | {status,reason}),quota_status:.quotaSemantics.status} ]}'
  [ "$code" != 124 ] || exit 124
done
