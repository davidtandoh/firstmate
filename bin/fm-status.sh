#!/usr/bin/env bash
# Append one worker status event, refusing publishing-ship done without its recorded review URL.
# Usage: fm-status.sh [--dry-run] <config-dir> <status-file> <line>
# Reads kind, mode, and forge from the status file's sibling .meta, so a promoted
# scout uses its current ship contract even with its original brief command.
# Missing or invalid delivery metadata refuses done; nonterminal events pass.
# Local-only ships, scouts, and secondmates do not need a PR URL.
# A refusal writes nothing and tells the worker to run its delivery pipeline.
# URL presence is not forge verification; the existing delivery gates own that.
# After an append, capture the opt-in fleet ledger best-effort as before.
# --dry-run validates and prints the status path without writing or ledger capture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

dry_run=0
case "${1:-}" in
  --help|-h) sed -n '2,/^set /{ /^set /d; s/^# *//; p; }' "$0"; exit 0 ;;
  --dry-run) dry_run=1; shift ;;
esac
[ "$#" -eq 3 ] || { echo 'usage: fm-status.sh [--dry-run] <config-dir> <status-file> <line>' >&2; exit 2; }
config=$1 status=$2 line=$3
case "$status" in *.status) ;; *) echo 'error: expected a .status file' >&2; exit 2 ;; esac
case "$line" in *$'\n'*|*$'\r'*) echo 'error: expected one status line' >&2; exit 2 ;; esac
if [ "$(status_line_verb "$line")" = "done" ]; then
  meta="${status%.status}.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo 'error: done requires task delivery metadata' >&2; exit 1; }
  kind=$(fm_dod_meta_value "$meta" kind) || kind=
  case "$kind" in
    scout|secondmate) ;;
    ship)
      mode=$(fm_dod_meta_value "$meta" mode) || mode=
      case "$mode" in
        local-only) ;;
        no-mistakes|direct-PR)
          note=$(status_line_note "$line")
          forge=$(fm_dod_meta_value "$meta" forge) || forge=
          valid=0
          if [ "$forge" = external ]; then
            recorded=$(fm_dod_meta_value "$meta" review) || recorded=
            url=$(fm_dod_review_url_from_done_note "$note") || url=
            if [ -n "$url" ] && [ "$url" = "$recorded" ] && fm_external_review_url_parse "$url" "$config"; then valid=1; fi
          else
            recorded=$(fm_dod_meta_value "$meta" pr) || recorded=
            url=$(fm_dod_ready_note_url "$note") || url=
            if [ -n "$url" ] && [ "$url" = "$recorded" ] && FM_CONFIG_OVERRIDE="$config" fm_pr_url_parse "$url"; then valid=1; fi
          fi
          [ "$valid" -eq 1 ] || {
            echo "error: $mode ship done requires its recorded PR/review URL; run the delivery pipeline, then use the registration handoff in the definition of done: append a blocked [key=review-registration] event with the published URL and wait for firstmate through the steering inbox before retrying done" >&2
            exit 1
          }
          ;;
        *) echo 'error: done requires a valid ship delivery mode' >&2; exit 1 ;;
      esac
      ;;
    *) echo 'error: done requires a valid task kind' >&2; exit 1 ;;
  esac
fi
if [ "$dry_run" -eq 1 ]; then
  printf 'would append: %s\n' "$status"
  exit 0
fi
printf '%s\n' "$line" >> "$status"
[ ! -e "$config/fleet-ledger" ] || "$ROOT/bin/fm-fleet-ledger.sh" appended "$config" "$status" >/dev/null 2>&1 || true
