#!/usr/bin/env bash
# Live probe: an empty pane shell renamed by Kiro's shell integration
# (argv0 "zsh (kiro-cli-term)") must read dead, not unreadable.
# Usage: kiro-term-shell-probe.sh <code-root>   (lab mechanics always from $PWD)
set -euo pipefail
ROOT=$PWD
CODE=${1:-$PWD}
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
H=$ROOT/bin/fm-herdr-lab.sh
S=$("$H" name kiro-term-probe)
echo "# lab session: $S ; code under test: $CODE"
TMPD=$(mktemp -d)
cleanup() { "$H" teardown "$S"; rm -rf "$TMPD"; }
trap cleanup EXIT
"$H" provision "$S"
. "$CODE/bin/backends/herdr.sh"
fm_backend_herdr_cli() { [ "$1" = "$S" ] || return 9; shift; "$H" run "$S" "$@"; }
lab() { "$H" run "$S" "$@"; }
ws=$(lab workspace create --label probe --cwd "$TMPD" --no-focus | jq -er '.result.workspace.workspace_id')
pane=$(lab tab create --workspace "$ws" --cwd "$TMPD" --label probe --no-focus | jq -er '.result.root_pane.pane_id')
lab pane run "$pane" 'exec -a "zsh (kiro-cli-term)" zsh -f' >/dev/null
sleep 2
info=$(lab pane process-info --pane "$pane")
echo "# herdr pane process-info (decorated empty shell):"
printf '%s' "$info" | jq -c '.result.process_info'
fg=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id')
echo "# ps comm/args: $(ps -p "$fg" -o comm=,args=)"
echo "# registration: $(lab agent get "$pane" 2>&1 | jq -r '.result.agent.agent_status // .error.code // "unreadable"')"
echo "pane_process_state=$(fm_backend_herdr_pane_process_state "$S" "$pane")"
echo "agent_state=$(fm_backend_herdr_agent_state "$S:$pane")"
