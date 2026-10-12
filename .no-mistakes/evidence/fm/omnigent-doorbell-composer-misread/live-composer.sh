#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/Users/davidtandoh/.no-mistakes/evidence/01M4S1RV3F6MMT47FFGC7HMQ2C
export LC_ALL=en_US.UTF-8
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB=$(mktemp -d "$ROOT/.composer-lab.XXXXXX")
export FM_HOME="$LAB/home" FM_HERDR_LAB_STATE_DIR="$LAB/tripwires"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name composer-proof)
pane=''; server=''; provisioned=0
lab() { "$HELPER" run "$SESSION" "$@"; }
cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$pane" ]; then
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    session=$(printf '%s\n' "$screen" | sed -n 's|^Omnigent: http://127.0.0.1:[0-9]*/c/\([a-f0-9]\{32\}\)[[:space:]]*$|\1|p')
    if [[ "$session" =~ ^[a-f0-9]{32}$ ]]; then
      endpoint="$server/v1/sessions/$session/resources/terminals"
      resources=$(curl -fsS --max-time 5 "$endpoint")
      if printf '%s' "$resources" | jq -e --arg s "$session" '.object == "list" and .has_more == false and all(.data[]; .session_id == $s and .type == "terminal" and (.id | test("^[A-Za-z0-9_-]+$")))' >/dev/null; then
        while IFS= read -r terminal; do
          [ -z "$terminal" ] || curl -fsS --max-time 5 -X DELETE "$endpoint/$terminal" >/dev/null
        done < <(printf '%s' "$resources" | jq -r '.data[].id')
        curl -fsS --max-time 5 "$endpoint" > "$E/live-terminal-cleanup.json"
      else rc=1; fi
    else printf 'Could not identify wrapper session from pane\n'; rc=1; fi
  fi
  if [ "$provisioned" = 1 ]; then "$HELPER" teardown "$SESSION" || rc=1; fi
  rm -rf "$LAB"
  printf 'live-check exit=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
server=$("$ROOT/bin/fm-omnigent.sh" run --dry-run claude | jq -er .server_url)
"$HELPER" provision "$SESSION"
provisioned=1
lab status --json > "$E/live-herdr-status.json"
ws=$(lab workspace create --label composer-proof --cwd "$ROOT" --no-focus | jq -er .result.workspace.workspace_id)
pane=$(lab tab create --workspace "$ws" --cwd "$ROOT" --label composer-proof --no-focus | jq -er .result.root_pane.pane_id)
. "$ROOT/bin/fm-task-inbox-lib.sh"
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() { [ "$1" = "$SESSION" ] || return 91; shift; lab "$@"; }
target="$SESSION:$pane"
launch=$(printf '%q ' env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE "FM_HOME=$FM_HOME" "$ROOT/bin/fm-omnigent.sh" run claude --dangerously-skip-permissions '')
lab pane run "$pane" "$launch"
ready=0
for ((i=0;i<30;i++)); do
  sleep 1
  cap=$(fm_backend_herdr_visible_capture_ansi "$target")
  printf '%s\n' "$cap" > "$E/live-startup.ansi"
  verdict=$(fm_backend_herdr_composer_state "$target")
  if [ "$verdict" = empty ]; then ready=1; break; fi
  if printf '%s' "$cap" | rg -qi 'trust this|Quick safety check|Allow external CLAUDE|Sign in|log in'; then break; fi
done
printf 'startup composer=%s ready=%s\n' "$verdict" "$ready"
fm_backend_herdr_visible_capture "$target" > "$E/live-startup.txt"
[ "$ready" = 1 ] || exit 3
mkdir -p "$FM_HOME/state/proof.inbox/handled"
printf 'Test record.\n' > "$FM_HOME/state/proof.inbox/001.msg"
for kind in ordinary multiline shell-example box-drawing; do
  case "$kind" in
    ordinary) draft='KEEP_THIS_DRAFT' ;;
    multiline) draft=$'first line\n\n ❯ keep this draft\nlast line' ;;
    shell-example) draft=$'first line\n\n $ ls\nlast line' ;;
    box-drawing) draft=$'draw this box\n ┌────┐\n │ │\n └────┘' ;;
  esac
  fm_backend_herdr_send_literal "$target" "$draft"
  sleep 1
  cap=$(fm_backend_herdr_visible_capture_ansi "$target")
  printf '%s\n' "$cap" > "$E/live-$kind.ansi"
  fm_backend_herdr_visible_capture "$target" > "$E/live-$kind.txt"
  verdict=$(fm_backend_herdr_composer_state "$target")
  content=$(fm_composer_extract_selected_content styled=1 "$cap")
  printf '%s classification=%s extracted=%s\n' "$kind" "$verdict" "$content"
  [ "$verdict" = pending ] || exit 1
  ring=0
  fm_task_inbox_ring herdr "$target" "$FM_HOME/state/proof.inbox/001.msg" || ring=$?
  after=$(fm_backend_herdr_visible_capture_ansi "$target")
  content_after=$(fm_composer_extract_selected_content styled=1 "$after")
  printf '%s doorbell_exit=%s unchanged=%s\n' "$kind" "$ring" "$([ "$content" = "$content_after" ] && echo true || echo false)"
  [ "$ring" = 1 ] && [ "$content" = "$content_after" ] || exit 1
  # Clear only this test's unsubmitted draft, one row at a time.
  for ((j=0;j<8;j++)); do fm_backend_herdr_send_key "$target" C-u; fm_backend_herdr_send_key "$target" Backspace; done
  sleep 1
  [ "$(fm_backend_herdr_composer_state "$target")" = empty ] || exit 4
done
