# shellcheck shell=bash
# Claude account collection and project binding. Sourced by the reporter,
# typed dispatch resolver, and spawn path.
# fm_quota_snapshot emits the quota-axi snapshot unchanged on single-account
# installations. An existing $HOME/.claude_b enables the second account.
# When present, it collects the ordinary personal
# login with CLAUDE_CONFIG_DIR unset and the GuideX login with its exact root
# selected. quota-axi alone reads credentials, caches, and quota semantics;
# --no-credential-refresh forbids delegated login renewal. No auth data is read
# or printed here. Schema 6 keys are claude-home and claude-guidex. A failed or
# invalid read of one account becomes that account's non-fresh row carrying a
# sign-in remedy, so the other account stays selectable; only two failed reads
# fail the collection. Each non-fresh Claude row carries state.remedy.
# fm_claude_repo_lane <project path or registration> <projects root> resolves
# physical paths; only a path under the physical ~/workspace/guidex qualifies.
# fm_claude_account_lane <snapshot JSON> <model> <repo lane> [<scoped floor JSON>]
# delegates selection to the shared quota jq contract. Empty means unknown;
# unavailable means every readable account is ineligible, so dispatch falls
# through to its other configured profiles. Fable ties use the repository lane.
# fm_claude_spawn_root <project> <projects root> <model> <claude executable> [<scoped floor JSON>]
# prints the automatic root, or an empty line for the ordinary personal login.
# The executable argument makes the status-only probe independently testable.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

fm_claude_guidex_root() {
  [ -d "$HOME/.claude_b" ] || return 0
  printf '%s\n' "$HOME/.claude_b"
}

fm_claude_repo_lane() {
  local project=$1 projects=$2 physical guidex
  case "$project" in
    projects/*) project="$projects/${project#projects/}" ;;
    /*) ;;
    *) [ ! -d "$projects/$project" ] || project="$projects/$project" ;;
  esac
  physical=$(cd "$project" 2>/dev/null && pwd -P) || physical=
  guidex=$(cd "$HOME/workspace/guidex" 2>/dev/null && pwd -P) || guidex=
  if [ -n "$physical" ] && [ -n "$guidex" ]; then
    case "$physical" in "$guidex"|"$guidex"/*) printf 'claude-guidex\n'; return 0 ;; esac
  fi
  printf 'claude-home\n'
}

fm_claude_account_lane() {
  local snapshot=$1 model=$2 repo=$3 floor=${4:-null} guidex
  guidex=$(fm_claude_guidex_root) || return 1
  if [ -z "$guidex" ]; then printf 'claude-home\n'; return 0; fi
  jq -rn --argjson snapshot "$snapshot" --arg model "$model" --arg repo "$repo" --argjson floor "$floor" \
    "$FM_QUOTA_ROW_JQ"'claude_task_lane($snapshot; $model; $repo; $floor)'
}

fm_claude_explicit_lane() {
  local guidex
  guidex=$(fm_claude_guidex_root) || return 1
  if [ -n "$guidex" ] && [ "$1" = "$guidex" ]; then
    printf 'claude-guidex\n'
  else
    printf 'claude-explicit\n'
  fi
}

fm_claude_dispatch_lane() {
  local config=$1 selection declared root guidex
  selection=$(fm_worker_account_resolve claude "$config" 'config/claude-account') || return 1
  if [ -n "$selection" ]; then
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    root=${root%%$'\t'*}
    if [ "$declared" = ordinary ]; then
      printf 'claude-home\n'
    else
      fm_claude_explicit_lane "$root"
    fi
  elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    fm_claude_explicit_lane "$CLAUDE_CONFIG_DIR"
  else
    guidex=$(fm_claude_guidex_root "$config") || return 1
    [ -n "$guidex" ] || printf 'claude-home\n'
  fi
}

fm_claude_floor_json() {
  jq -csS "$FM_QUOTA_ROW_JQ"'
    if length != 1 then error("expected one Claude floor value") else .[0] |
      (if . == null then [] elif type == "object" then [.] else . end) |
      if type != "array" then error("invalid Claude floors")
      elif all(.[]; type == "object" and (.scope | type == "string" and length > 0) and
        (.min_percent | type == "number" and . >= 0 and . <= 100))
      then claude_floors(.) else error("invalid Claude floors") end
    end' <<< "$1"
}

fm_claude_spawn_root() {
  local project=$1 projects=$2 model=$3 executable=$4 floor=${5:-null} repo lane root snapshot fable guidex
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_CONFIG_DIR"
    return $?
  fi
  guidex=$(fm_claude_guidex_root) || return 1
  if [ -z "$guidex" ]; then printf '\n'; return 0; fi
  repo=$(fm_claude_repo_lane "$project" "$projects") || return 1
  lane=$repo
  fable=$(jq -rn --arg model "$model" "$FM_QUOTA_ROW_JQ"'claude_is_fable($model)') || return 1
  if [ "$fable" = true ]; then
    snapshot=$(fm_quota_snapshot) || { echo 'error: cannot collect Claude account quota' >&2; return 1; }
    lane=$(fm_claude_account_lane "$snapshot" "$model" "$repo" "$floor") || return 1
    case "$lane" in
      claude-home|claude-guidex) ;;
      *) echo "error: Claude Fable accounts ${lane:-unknown}; resolve the remaining dispatch profiles" >&2; return 1 ;;
    esac
  fi
  root=
  [ "$lane" != claude-guidex ] || root=$guidex
  if [ -n "$lane" ]; then
    # The shared status probe removes ambient credentials and keeps USER and
    # LOGNAME. Recover the OS login name if the caller omitted them.
    local login_user=${USER:-} login_name=${LOGNAME:-}
    [ -n "$login_user" ] || login_user=$(id -un) || return 1
    [ -n "$login_name" ] || login_name=$login_user
    USER="$login_user" LOGNAME="$login_name" fm_worker_account_check claude "$lane" "$root" "$executable" '' 'automatic Claude account routing' || return 1
  fi
  printf '%s\n' "$root"
}

fm_quota_snapshot() {
  local base guidex name root
  local -a clean=(env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR)
  root=$(fm_claude_guidex_root) || return 1
  if [ -z "$root" ]; then
    quota-axi --json
    return $?
  fi
  for name in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do clean+=(-u "$name"); done
  # A valid snapshot is kept even from a failing read, since it can carry the
  # account's own non-fresh state and remedy.
  base=$(fm_run_timed 45 "${clean[@]}" quota-axi --json --no-credential-refresh 2>/dev/null) || true
  base=$(fm_quota_account_read <<< "$base") || base=null
  guidex=$(fm_run_timed 45 "${clean[@]}" "CLAUDE_CONFIG_DIR=$root" quota-axi --provider claude --json --no-credential-refresh 2>/dev/null) || true
  guidex=$(fm_quota_account_read <<< "$guidex") || guidex=null
  [ "$base" != null ] || [ "$guidex" != null ] || return 1
  jq -cSn --argjson base "$base" --argjson guidex "$guidex" --arg root "$root" '
    def account($read; $key; $login):
      ($read.providers // [] | map(select(.provider == "claude"))) as $rows |
      (if ($rows | length) == 1 then $rows[0]
       else {provider:"claude", state:{status:"unreadable"}, windows:[],
             quotaSemantics:{status:"unknown", effectiveAvailability:[]}} end) |
      .accountKey = $key |
      if (.state.status // "fresh") == "fresh" then .
      else .state.remedy = (.state.remedy // "sign in with \($login), then /login") end;
    ($base // {}) | .schemaVersion=6 |
      .providers=([.providers[]? | select(.provider != "claude") | .accountKey=(.accountKey // "default")] +
        [account($base; "claude-home"; "env -u CLAUDE_CONFIG_DIR claude"),
         account($guidex; "claude-guidex"; "CLAUDE_CONFIG_DIR=\($root) claude")])'
}

# A usable account read is one valid quota-axi snapshot; anything else is an
# unreadable account that fm_quota_snapshot reports instead of failing.
fm_quota_account_read() {
  local read
  read=$(cat) || return 1
  [ -n "$read" ] || return 1
  printf '%s\n' "$read" | fm_quota_json_valid || return 1
  printf '%s\n' "$read"
}
