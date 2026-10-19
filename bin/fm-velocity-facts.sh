#!/usr/bin/env bash
# Collect retained home records for [now-86400, now), without changing sources.
# Usage: fm-velocity-facts.sh [--home DIR] [--now EPOCH] [--include-prs]
#                             [--reuse] [--dry-run] [--json]
# Writes data/velocity-audit/<UTC end-date>/facts.json exclusively, never replaces.
# --include-prs queries at most 10 recorded GitHub PRs via gh-axi (5s each).
# Sources, limits, omissions and schema are owned by fm-velocity-facts.py.
# --dry-run prints the destination and performs no writes or network calls.
# --reuse validates an existing daily snapshot instead of replacing it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/bin/fm-velocity-facts.py" "$@"
