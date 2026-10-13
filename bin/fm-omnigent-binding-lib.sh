#!/usr/bin/env bash
# Firstmate's association with a public Omnigent binding, not a custody owner.
# The task's existing data directory holds omnigent-binding.json. An empty
# private reservation refuses retries after an interrupted launch. Never guess
# a missing legacy binding or enumerate Omnigent's private records.
# Callers load fm-backend.sh, fm-pr-lib.sh and fm-backlog-transition-lib.sh.
# Mutating/uniqueness checks hold this home's existing task-set lock.

fm_omnigent_task_context() { # <task-meta> <task-data>; sets BINDING_FILE/WORKSPACE
  local meta=$1 data=$2 id parent
  fm_dirname_to BINDING_STATE "$meta"
  fm_basename_to id "$meta"
  id=${id%.meta}
  fm_task_id_creation_valid "$id" && [ "$meta" = "$BINDING_STATE/$id.meta" ] || return 1
  fm_basename_to parent "$data"
  [ "$parent" = "$id" ] || return 1
  fm_backlog_record_present "$meta" 'binding task metadata' "$BINDING_STATE" || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  [ "$(fm_backend_meta_exact_value "$meta" harness)" = codex ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" omnigent)" = on ] || return 1
  BINDING_WORKSPACE=$(fm_backend_meta_exact_value "$meta" worktree) || return 1
  [ "$BINDING_WORKSPACE" = "$(pwd -P)" ] || return 1
  fm_dirname_to BINDING_DATA_ROOT "$data"
  fm_backlog_directory_present "$data" 'binding task data' || return 1
  BINDING_FILE="$data/omnigent-binding.json"
  fm_backlog_record_parent_authorized "$BINDING_FILE" 'task binding' "$BINDING_DATA_ROOT" || return 1
}

fm_omnigent_binding_read() { # <file>; sets BINDING_JSON
  local file=$1 parent device identity after LC_ALL=C
  fm_dirname_to parent "$file"
  device=$(fm_pr_file_device "$parent") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  identity=$(fm_pr_file_identity "$file") || return 1
  # Preserve trailing newlines so padding cannot bypass the byte limit.
  BINDING_JSON=$(head -c 65537 "$file" && printf '.') || return 1
  BINDING_JSON=${BINDING_JSON%.}
  [ "${#BINDING_JSON}" -le 65536 ] || return 1
  after=$(fm_pr_file_identity "$file") || return 1
  [ "$identity" = "$after" ] && fm_pr_private_file_valid "$file" 600 "$device" || return 1
  printf '%s' "$BINDING_JSON" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1
}

fm_omnigent_binding_unique() { # <this-file> <JSON>; checks only existing task IDs
  local own=$1 binding=$2 meta id other candidate
  for meta in "$BINDING_STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    fm_backlog_record_present "$meta" 'binding task metadata' "$BINDING_STATE" || return 1
    fm_basename_to id "$meta"
    id=${id%.meta}
    fm_task_id_creation_valid "$id" || return 1
    other="$BINDING_DATA_ROOT/$id/omnigent-binding.json"
    [ "$other" != "$own" ] || continue
    [ -e "$other" ] || [ -L "$other" ] || continue
    fm_backlog_record_present "$other" 'task binding' "$BINDING_DATA_ROOT" || return 1
    fm_omnigent_binding_read "$other" || return 1
    candidate=$BINDING_JSON
    # Incomplete/malformed associations cannot prove that another task is free.
    printf '%s' "$candidate" | jq -L "$SCRIPT_DIR" -se 'include "fm-omnigent-contract";
      fm_omnigent_binding_verified(.[0].workspace; .[0].endpoint)' >/dev/null 2>&1 || return 1
    printf '%s' "$candidate" | jq -se --argjson binding "$binding" \
      '.[0].session_id != $binding.session_id and .[0].runner_id != $binding.runner_id and .[0].native != $binding.native' \
      >/dev/null 2>&1 || return 1
  done
}
