#!/usr/bin/env bash
# fm-correction.sh - the captain corrections log and its repeat rule.
#
# Firstmate logs every captain correction, and every known mistake a worker
# repeats, as one row here. A class of mistake that recurs is a guard
# candidate: the second row in a class files a backlog task held for the
# captain that asks for a `correct` task (Agent Kit `correct` skill) to turn
# the lesson into a structural guard. Nothing is ever dispatched automatically.
#
# Usage:
#   fm-correction.sh add --class <slug> --description <text> --evidence <pointer> [--date YYYY-MM-DD]
#   fm-correction.sh list [--class <slug>]
#   fm-correction.sh repeats
#
# LOG FORMAT. `$FM_HOME/data/corrections.md` (FM_DATA_OVERRIDE replaces the
# data directory), a Markdown table created with this header on first `add`:
#   | Date | Class | Description | Evidence |
#   |---|---|---|---|
# One row per correction: a YYYY-MM-DD date, a lowercase class slug
# ([a-z0-9-], at most 64 characters), one plain line describing the mistake,
# and one evidence pointer (a PR URL, commit, file:line, or record path). Text
# fields refuse `|`, line breaks, and control characters rather than escaping
# them. Only rows of that shape are read; any other line is ignored. An
# existing log without the header row is refused so rows never land in a
# foreign table.
#
# REPEAT RULE. When `add` leaves a class with two or more rows, it runs
# `bin/fm-captain-hold.sh hold correct-<class>` with the class's evidence as
# the reason on the first repeat. An open task already covering the class is
# left unchanged, including released or in-flight work. After completion, a
# new task uses correct-<class>-YYYY-MM-DD (the correction date), adding a
# numeric suffix from 2 if needed. Archived completed ids remain reserved.
# The hold is the captain's approval point;
# a task read or hold failure exits 1 after the row is already logged.
#
# Output: `add` prints `logged: <class> (<n> in class)` and, on a repeat,
# `correct task held: <task-id>` or `correct task already covers class: <task-id>`.
# `list` prints matching rows as
# `<date>\t<class>\t<description>\t<evidence>`. `repeats` prints
# `<class>\t<count>` for every class with two or more rows.
# Exit codes: 0 success, 1 failure, 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="$DATA/corrections.md"
HEADER='| Date | Class | Description | Evidence |'

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# LOG FORMAT/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

die() {
  printf 'fm-correction: %s\n' "$1" >&2
  exit "${2:-1}"
}

plain() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || die "$label must not be empty"
  case "$value" in
    *'|'*) die "$label must not contain |" ;;
  esac
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    die "$label must be one plain line with no line breaks or control characters"
  fi
  if [[ "$value" =~ ^[[:space:]] || "$value" =~ [[:space:]]$ ]]; then
    die "$label must have no leading or trailing whitespace"
  fi
}

slug() {  # <value>
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
    || die "class must be a lowercase slug of letters, digits and hyphens (at most 64): $1"
}

# Rows as tab-separated date, class, description, evidence.
rows() {
  [ -f "$LOG" ] || return 0
  awk -F'|' '
    NF == 6 && $1 == "" && $6 == "" {
      for (i = 2; i <= 5; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
      if ($2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $3 ~ /^[a-z0-9][a-z0-9-]*$/)
        printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $5
    }' "$LOG"
}

command_add() {
  local class='' description='' evidence='' date='' count reason tasks ids id task suffix=2 archive_status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class|--description|--evidence|--date)
        [ "$#" -ge 2 ] || die "$1 needs a value" 2
        case "$1" in
          --class) class=$2 ;;
          --description) description=$2 ;;
          --evidence) evidence=$2 ;;
          --date) date=$2 ;;
        esac
        shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [ -n "$class" ] && [ -n "$description" ] && [ -n "$evidence" ] || { usage >&2; exit 2; }
  slug "$class"
  plain description "$description"
  plain evidence "$evidence"
  [ -n "$date" ] || date=$(date -u +%Y-%m-%d)
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD: $date"

  mkdir -p "$DATA"
  if [ -f "$LOG" ]; then
    grep -qxF "$HEADER" "$LOG" \
      || die "$LOG has no '$HEADER' table; move its rows into that table before logging"
  else
    {
      printf '# Captain corrections log\n\n'
      printf 'One row per captain correction or repeated known mistake, appended by bin/fm-correction.sh add.\n'
      printf 'The second row in a class holds a correct-<class> task for the captain.\n\n'
      printf '%s\n|---|---|---|---|\n' "$HEADER"
    } > "$LOG"
  fi
  printf '| %s | %s | %s | %s |\n' "$date" "$class" "$description" "$evidence" >> "$LOG"

  count=$(rows | awk -F'\t' -v c="$class" '$2 == c' | wc -l | tr -d ' ')
  printf 'logged: %s (%s in class)\n' "$class" "$count"
  [ "$count" -ge 2 ] || return 0

  tasks=$(fm_backlog_row_list "$DATA") || die "logged the row, but could not list correct tasks"
  ids=$(printf '%s\n' "$tasks" | awk -F, '/^  [A-Za-z0-9._-]+,/ && $2 != "done" {
    sub(/^ +/, "", $1); print $1
  }')
  while IFS= read -r id; do
    if [ "$id" = "correct-$class" ] || [[ "$id" =~ ^correct-$class-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$ ]]; then
      printf 'correct task already covers class: %s\n' "$id"
      return 0
    fi
  done <<< "$ids"

  task="correct-$class"
  while :; do
    if fm_backlog_row_probe "$DATA" "$task"; then
      if [ "${FM_BACKLOG_ROW_STATE%% *}" != done ]; then
        printf 'correct task already covers class: %s\n' "$task"
        return 0
      fi
    else
      [ "$FM_BACKLOG_ROW_RESULT" = not_found ] \
        || die "logged the row, but could not read $task: $FM_BACKLOG_ROW_ERROR"
      archive_status=0
      "$SCRIPT_DIR/fm-captain-hold.sh" archived "$task" || archive_status=$?
      case "$archive_status" in
        0) ;;
        1) break ;;
        *) die "logged the row, but could not read the archive for $task" ;;
      esac
    fi
    if [ "$task" = "correct-$class" ]; then
      task="correct-$class-$date"
    else
      task="correct-$class-$date-$suffix"
      suffix=$((suffix + 1))
    fi
  done

  reason="Correction class $class repeated $count times; approve a correct task to turn it into a structural guard proven against a past instance. Evidence: $(rows | awk -F'\t' -v c="$class" '$2 == c { printf "%s%s %s", sep, $1, $4; sep = "; " }')"
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" \
    --title "Correct repeated mistake: $class" --reason "$reason" >/dev/null \
    || die "logged the row, but could not hold $task"
  printf 'correct task held: %s\n' "$task"
}

command_list() {
  local class=''
  case "${1:-}" in
    '') ;;
    --class) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; class=$2; slug "$class" ;;
    *) usage >&2; exit 2 ;;
  esac
  rows | awk -F'\t' -v c="$class" 'c == "" || $2 == c'
}

command_repeats() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  rows | awk -F'\t' '{ n[$2]++; if (!($2 in seen)) { seen[$2] = 1; order[++k] = $2 } }
    END { for (i = 1; i <= k; i++) if (n[order[i]] >= 2) printf "%s\t%d\n", order[i], n[order[i]] }'
}

case "${1:-}" in
  add) shift; command_add "$@" ;;
  list) shift; command_list "$@" ;;
  repeats) shift; command_repeats "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
