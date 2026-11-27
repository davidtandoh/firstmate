#!/usr/bin/env bash
# Receive a pushed Omnigent owner window over fm-on.sh's authenticated stdin.
# Usage: fm-upgrade-window.sh receive <https-origin> [--dry-run]
# Reads at most 65537 bytes; rejects over 64 KiB, unsafe paths, mismatched
# origins, malformed envelopes, future timestamps, and copies older than 600s.
# Atomically replaces the per-origin copy in FM_HOME/state. --dry-run prints the destination and writes nothing.
# The envelope and cadence contract belongs to fm-upgrade-window-lib.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-upgrade-window-lib.sh"
if [ "${1:-}" = --help ]; then sed -n '2,8p' "$0" | sed 's/^# *//'; exit 0; fi
[ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ "$1" = receive ] || exit 2
server=$2
[[ "$server" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || exit 2
[ "$#" = 2 ] || [ "$3" = --dry-run ] || exit 2
payload=$(head -c 65537)
[ "$(printf '%s' "$payload" | wc -c)" -le 65536 ] || exit 1
printf '%s' "$payload" | fm_upgrade_window_unpack "$server" "$(date +%s)" >/dev/null
file=$(fm_upgrade_window_copy_path "$server")
if [ "${3:-}" = --dry-run ]; then printf 'updated %s\n' "$file"; exit 0; fi
[ ! -L "${file%/*}" ] && [ ! -L "$file" ] || exit 1
mkdir -p "${file%/*}"
tmp=$(mktemp "$file.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$payload" > "$tmp"
mv -f "$tmp" "$file"
printf 'updated %s\n' "$file"
