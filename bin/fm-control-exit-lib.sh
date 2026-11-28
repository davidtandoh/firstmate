#!/usr/bin/env bash
# Shared lifecycle implementation for fm-control and locked Omnigent teardown.
# Callers provide the validated task context and hold its lifecycle lock.
# Teardown also holds the task-record lock and sets CONTROL_RECORD_LOCKED=1.
# The ordinary control path owns busy retirement; teardown owns its own cleanup.
set -euo pipefail

agent_state() {
  local state native remaining
  local -a native_command
  state=$(fm_backend_agent_state "$BACKEND" "$T")
  if [ "${VERIFY_OMNIGENT_STOP:-0}" = 1 ] && [ "$(fm_meta_get "$META" omnigent)" = on ]; then
    if [ "$state" = dead ] && [ "${OMNIGENT_EXIT_DELIVERED:-0}" = 1 ]; then
      native_command=(bash "$SCRIPT_DIR/fm-omnigent.sh" _confirm-exit "$META"
        "$OMNIGENT_EXIT_SESSION" "$OMNIGENT_EXIT_SERVER" "$OMNIGENT_EXIT_GEN")
      [ "${OMNIGENT_NATIVE_STOP:-0}" != 1 ] || native_command+=(native-stop)
    else
      # shellcheck disable=SC2016 # The child shell expands its positional arguments.
      native_command=(bash -c '
        . "$1"
        fm_backend_omnigent_agent_state "$2" "$3"
      ' _ "$SCRIPT_DIR/fm-backend.sh" "$state" "$META")
    fi
    if [ -n "${1:-}" ]; then
      if remaining=$(awk -v deadline="$1" -v now="$(fm_timing_now_ms)" 'BEGIN {
        remaining = (deadline - now) / 1000
        if (remaining <= 0) exit 1
        printf "%.6f", remaining
      }'); then
        native=$(fm_run_timed "$remaining" "${native_command[@]}" 2>/dev/null) || native=unknown
      else
        native=unknown
      fi
    else
      native=$("${native_command[@]}") || native=unknown
    fi
    if [ "$state:$native" != alive:dead ]; then state=$native; fi
  fi
  printf '%s' "$state"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state=unknown want deadline pause
  shift
  deadline=$(awk -v now="$(fm_timing_now_ms)" -v timeout="$timeout" 'BEGIN {
    printf "%.0f", now + timeout * 1000
  }') || { printf unknown; return 1; }
  while :; do
    awk -v deadline="$deadline" -v now="$(fm_timing_now_ms)" 'BEGIN {
      exit !(now < deadline)
    }' || break
    state=$(agent_state "$deadline")
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    pause=$(awk -v deadline="$deadline" -v now="$(fm_timing_now_ms)" -v poll="$POLL" 'BEGIN {
      remaining = (deadline - now) / 1000
      if (remaining <= 0) exit 1
      printf "%.6f", (remaining < poll ? remaining : poll)
    }') || break
    sleep "$pause"
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# refuse_blocking_prompt: the screen is a dialog a confirming Enter would
# answer. Name it and stop. Do not type Escape or an option: both dismiss
# or choose.
refuse_blocking_prompt() {  # <dialog-name>
  die "task $ID is blocked on a prompt: $1. Refusing to type Enter into it."
}

# rendered_matches <ere>: whether any row of the visible viewport matches.
# An unreadable viewport is a no, so every caller treats it as missing proof.
rendered_matches() {  # <ere>
  local screen
  screen=$(fm_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  printf '%s\n' "$screen" | grep -Eq -- "$1"
}

# wait_rendered <ere> <timeout>: poll the viewport until a row matches.
wait_rendered() {  # <ere> <timeout>
  local elapsed=0 step
  step=$(awk -v p="$POLL" 'BEGIN{printf "%s", (p < 0.1 ? p : 0.1)}')
  while :; do
    rendered_matches "$1" && return 0
    awk -v e="$elapsed" -v t="$2" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$step"
    elapsed=$(awk -v e="$elapsed" -v p="$step" 'BEGIN{printf "%.3f", e + p}')
  done
}

# dismiss_interrupt_hazard <key> <ere>: after the presses, close a surface a
# mistimed press opened (Devin's revert picker) with one more key, before
# anything else can be typed into it. Sets INTERRUPT_HAZARD.
dismiss_interrupt_hazard() {  # <key> <ere>
  local key=$1 hazard=$2 gap
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  sleep "$gap"
  rendered_matches "$hazard" || return 0
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "task $ID shows the $HARNESS revert picker after its interrupt, and the $key that closes it was not delivered; nothing else was typed. Close it with $key, never Enter, before any other action"
  sleep "$gap"
  ! rendered_matches "$hazard" \
    || die "task $ID still shows the $HARNESS revert picker after one $key; nothing else was typed. Close it with $key, never Enter, before any other action"
  INTERRUPT_HAZARD=dismissed
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it. An adapter
# with an arm signal (fm_control_interrupt_arm_signal) gets each later press
# only after the viewport proves the first one armed a running turn, and never
# sooner than its press gap; without that proof INTERRUPT_ARMED=no and no
# further press is sent. Its hazard surface is then closed before returning.
send_interrupt_keys() {
  local key repeat clear arm hazard gap i=0
  if [ "$HARNESS" = hermes ] && [ "$(fm_backend_composer_state "$BACKEND" "$T")" != empty ]; then
    die 'Hermes double-Escape clears an unsent draft; interrupt requires a proven empty composer'
  fi
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  arm=$(fm_control_interrupt_arm_signal "$HARNESS")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  gap=$(fm_control_interrupt_press_gap "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  [ -z "$arm$hazard" ] || fm_backend_visible_capture_supported "$BACKEND" \
    || die "harness $HARNESS must see its screen between interrupt presses, because a repeated $key on an idle agent opens its revert picker, and the $BACKEND backend has no verified viewport read; refusing to press blind"
  INTERRUPT_ARMED=yes
  INTERRUPT_HAZARD=none
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -lt "$repeat" ] || break
    sleep "$gap"
    if [ -n "$arm" ] && ! wait_rendered "$arm" "$ARM_WAIT"; then
      INTERRUPT_ARMED=no
      break
    fi
  done
  [ -z "$hazard" ] || dismiss_interrupt_hazard "$key" "$hazard"
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery. `not-running` means an armed
# adapter's first press rendered no running turn, so nothing was cancelled; a
# dismissed revert picker is reported beside the claim.
# The rest transport (polytoken) takes a typed branch before any key is read:
# the TUI has no interrupt chord at all (fm_control_interrupt_transport), so
# POST /turn/cancel on the session daemon is the one verified interrupt, with
# its typed acknowledgement (cancel_requested plus the turn settling) as the
# claim, and the busy close written here because a cancelled turn emits no
# stop hook (verified live).
deliver_interrupt() {
  local cancel devin_gen='' port cred token
  if [ "$(fm_control_interrupt_transport "$HARNESS")" = rest ]; then
    port=$(fm_meta_get "$META" polytoken_port)
    cred=$(fm_meta_get "$META" polytoken_credential)
    if [ -z "$port" ] || [ -z "$cred" ]; then
      die "task $ID records no polytoken session binding (port or credential absent from its record); the REST control verbs address the session's own daemon, so an interrupt cannot be delivered without it. The session has likely ended or was launched raw; reconcile the task or relaunch it"
    fi
    token=$(fm_polytoken_credential_token "$cred") || token=
    [ -n "$token" ] || die "task $ID's polytoken credential at $cred is missing or unreadable, so the session cannot be interrupted through its daemon; the session has likely ended. Reconcile the task or relaunch it"
    # A cancelled turn emits no stop hook (verified live), so the close the
    # hooks would have written lands with the cancel: the settled turn is the
    # typed proof this incarnation is no longer busy, unless a queued prompt
    # has reopened it (fm_polytoken_interrupt_task).
    cancel=$(fm_polytoken_interrupt_task "$SCRIPT_DIR" "$STATE" "$ID" "$port" "$token" "$SETTLE_WAIT") \
      || die "task $ID's polytoken turn cancel was not acknowledged on port $port within ${SETTLE_WAIT}s; the interrupt status is unknown, so no further control action is safe here"
    INTERRUPT_ARMED=yes
    INTERRUPT_HAZARD=none
    printf '%s' "$cancel"
    return 0
  fi
  # Devin does not emit Stop for cancellation. Capture this incarnation before
  # keys, then invalidate its state conservatively rather than claiming idle.
  if [ "$HARNESS" = devin ]; then
    devin_gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
  fi
  # T3 Code has no keys: its native interrupt confirms the run's end itself.
  if [ "$BACKEND" = t3code ]; then
    cancel=$(fm_backend_t3code_native_interrupt "$T") \
      || die "interrupt was not delivered to task $ID on $BACKEND"
    printf '%s' "${cancel:-unconfirmed}"
    return 0
  fi
  prepare_interrupt_ack
  send_interrupt_keys
  if [ "$INTERRUPT_ARMED" = no ]; then
    cancel=not-running
  else
    cancel=$(interrupt_cancel_claim)
    if [ "$HARNESS" = devin ] && [ -n "$devin_gen" ]; then
      "$SCRIPT_DIR/fm-busy-event.sh" apply "$STATE" "$ID" unknown \
        --gen "$devin_gen" --source fm-interrupt --event interrupt >/dev/null 2>&1 || true
    fi
  fi
  [ "$INTERRUPT_HAZARD" = none ] || cancel="$cancel revert-picker=$INTERRUPT_HAZARD"
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

# Drop busy_gen from the task record when it still names <gen>.
# fm-busy-event.sh owns the sidecar and the record; fm_backlog_atomic_transition
# publish owns the task record. Clearing the line inside the busy writer would
# take the task-record lock that teardown and spawn already hold; the busy
# writer is their child process, so it would wait on a live holder that is
# itself waiting on the child, and neither would ever proceed.
clear_retired_meta_busy_gen() {  # <gen>
  local gen=$1 meta="$STATE/$ID.meta" lock tmp current line
  [ -n "$gen" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  if ! declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  fi
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock"
  current=$(fm_meta_get "$meta" busy_gen)
  if [ "$current" != "$gen" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.retire.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      busy_gen=*) ;;
      *)
        printf '%s\n' "$line" >> "$tmp" || {
          rm -f "$tmp"
          fm_lock_release "$lock"
          return 1
        }
        ;;
    esac
  done < "$meta" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

retire_busy_incarnation() {
  local gen=
  [ "${CONTROL_RECORD_LOCKED:-0}" != 1 ] || return 0
  if [ -f "$STATE/$ID.busy-gen" ]; then
    gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
    if [ -n "$gen" ] \
      && "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$gen" >/dev/null 2>&1; then
      clear_retired_meta_busy_gen "$gen" || true
    fi
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd hazard verdict composer_state cancel absence interrupt_result=not-needed dialog
  local VERIFY_OMNIGENT_STOP=0 OMNIGENT_EXIT_DELIVERED=0
  local OMNIGENT_NATIVE_STOP=0
  local OMNIGENT_EXIT_SESSION='' OMNIGENT_EXIT_SERVER='' OMNIGENT_EXIT_GEN=''
  require_state_verified_backend exit
  fm_control_backend_exit_supported "$BACKEND" \
    || die "task $ID runs on the $BACKEND backend, whose T3 Orchestrator V2 tools have no session stop, so 'exit' cannot stop its agent; 'interrupt' ends the running turn and teardown archives the thread"
  if [ "$(fm_meta_get "$META" omnigent)" = on ]; then
    if [ "${CONTROL_RECORD_LOCKED:-0}" = 1 ]; then
      "$SCRIPT_DIR/fm-omnigent.sh" capture --record-locked "$META" || true
    else
      "$SCRIPT_DIR/fm-omnigent.sh" capture "$META" || true
    fi
  fi
  state=$(agent_state)
  verdict=$(fm_backend_omnigent_agent_state "$state" "$META")
  if [ "$state" = dead ] && [ "$verdict" = unknown ] && [ "$HARNESS" = codex ] \
    && [ "$(fm_meta_get "$META" omnigent)" = on ]; then
    # A serve switch can detach every client while native sessions survive.
    # The exact-session stop verifies the binding independently of the client;
    # its acknowledgement alone is not positive evidence that the owner ended.
    OMNIGENT_EXIT_SESSION=$(fm_meta_get "$META" omnigent_session)
    OMNIGENT_EXIT_SERVER=$(fm_meta_get "$META" omnigent_server)
    OMNIGENT_EXIT_GEN=$(fm_meta_get "$META" spawn_gen)
    "$SCRIPT_DIR/fm-omnigent.sh" _stop-codex "$META" \
      "$OMNIGENT_EXIT_SESSION" "$OMNIGENT_EXIT_SERVER" "$OMNIGENT_EXIT_GEN" \
      || die "task $ID's Omnigent native owner is unknown; detached native-stop=unconfirmed"
    VERIFY_OMNIGENT_STOP=1 OMNIGENT_EXIT_DELIVERED=1 OMNIGENT_NATIVE_STOP=1
    wait_agent_state "$EXIT_WAIT" dead >/dev/null \
      || die "task $ID's detached Omnigent native-stop=unconfirmed; preserving the native owner and endpoint"
    retire_busy_incarnation
    printf 'stopped'
    return 0
  fi
  [ "$verdict" != unknown ] || die "task $ID's Omnigent native owner is unknown; attach-client state cannot authorize stop or replacement"
  if [ "$state" = alive ] && [ "$verdict" = dead ]; then
    "$SCRIPT_DIR/fm-omnigent.sh" stop-attach "$META" \
      || die "could not stop task $ID's retained Omnigent attach client"
    wait_agent_state "$EXIT_WAIT" dead >/dev/null \
      || die "task $ID's retained Omnigent attach client was not confirmed stopped"
    [ "$(fm_backend_omnigent_agent_state dead "$META")" = dead ] \
      || die "task $ID's attach client stopped, but its native owner is not proven absent"
    retire_busy_incarnation
    printf 'stopped'
    return 0
  fi
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    *)
      fm_control_absence_recheck_applies "$BACKEND" "$state" \
        || die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint"
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$META")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads '$state', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
  esac
  # Subsequent waits must prove native absence as well as attach-client exit.
  VERIFY_OMNIGENT_STOP=1
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS" "$OPENCODE_MAJOR")
  hazard=$(fm_control_interrupt_hazard_signal "$HARNESS")
  if [ -n "$hazard" ] && rendered_matches "$hazard"; then
    die "task $ID shows the $HARNESS revert picker, where typed text becomes a search and Enter reverts file changes; refusing to type the $cmd exit command. Close it with $(fm_control_interrupt_key "$HARNESS"), never Enter, then retry '$VERB'"
  fi
  : > "$FM_COMPOSER_DIALOG_SINK" \
    || die "task $ID's dialog check could not be recorded"
  composer_state=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
    || composer_state=unknown
  # The classify that filled the sink ran in a subshell, so read the file
  # rather than a function that subshell sourced.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    refuse_blocking_prompt "$dialog"
  fi
  case "$composer_state" in
    empty) ;;
    pending)
      die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Clear or submit the pending text, then retry '$VERB'"
      ;;
    *)
      die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'"
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter. OpenCode 2 exits from an empty composer on a
  # single Ctrl-C (verified on 2.0.11, 2.0.21, and 2.0.22); typing /exit also
  # exits but opens a completion popup, so the raw key plane avoids that popup
  # interacting with the typed submit verification. A Ctrl-C over leftover
  # composer text only clears it, so Ctrl-U clears the composer first and one
  # more Ctrl-C follows if the agent is still alive.
  OMNIGENT_EXIT_SESSION=$(fm_meta_get "$META" omnigent_session)
  OMNIGENT_EXIT_SERVER=$(fm_meta_get "$META" omnigent_server)
  OMNIGENT_EXIT_GEN=$(fm_meta_get "$META" spawn_gen)
  case "$cmd" in
    C-c)
      fm_backend_send_key "$BACKEND" "$T" C-u "$LABEL" \
        || die "the exit key could not be sent to task $ID on $BACKEND"
      fm_backend_send_key "$BACKEND" "$T" C-c "$LABEL" \
        || die "the exit key could not be sent to task $ID on $BACKEND"
      OMNIGENT_EXIT_DELIVERED=1
      if ! wait_agent_state "$SETTLE_WAIT" dead >/dev/null; then
        fm_backend_send_key "$BACKEND" "$T" C-c "$LABEL" \
          || die "the exit key could not be sent to task $ID on $BACKEND"
      fi
      ;;
    *)
      verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
        || die "the exit command could not be sent to task $ID on $BACKEND"
      [ "$verdict" != send-failed ] \
        || die "the exit command could not be sent to task $ID on $BACKEND"
      OMNIGENT_EXIT_DELIVERED=1
      # The submitting Enter can open the picker. The agent is still alive, and
      # another Enter would confirm the selected row. A dead agent may leave the
      # same text behind; that is not a prompt still waiting.
      if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
        dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
        if [ "$(agent_state)" != dead ]; then
          refuse_blocking_prompt "$dialog"
        fi
      fi
      ;;
  esac
  if [ "$HARNESS" = codex ] && [ "$(fm_meta_get "$META" omnigent)" = on ]; then
    # The TUI and the app server have different owners. /quit can detach the
    # TUI while the runner keeps the app server alive, so stop that exact
    # native session through its owner before accepting attach-client exit.
    "$SCRIPT_DIR/fm-omnigent.sh" _stop-codex "$META" \
      "$OMNIGENT_EXIT_SESSION" "$OMNIGENT_EXIT_SERVER" "$OMNIGENT_EXIT_GEN" \
      || die "exit-delivered $ID native-stop=unconfirmed; preserving the native owner and endpoint"
    OMNIGENT_NATIVE_STOP=1
  fi
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    # A submit can return before any read sees the picker: a native busy
    # verdict needs no composer read, and a cleared composer can be read
    # before the picker renders. Read the screen once more here.
    : > "$FM_COMPOSER_DIALOG_SINK" || true
    fm_backend_composer_state "$BACKEND" "$T" "$LABEL" >/dev/null 2>&1 || true
    if [ -s "$FM_COMPOSER_DIALOG_SINK" ]; then
      refuse_blocking_prompt "$(cat "$FM_COMPOSER_DIALOG_SINK")"
    fi
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# Stop and retire history while the caller holds the existing control and
# record locks. No endpoint close, process reap or lease release precedes this.
fm_control_omnigent_close_locked() (
  local META=$1 ID=$2 STATE BACKEND T LABEL HARNESS OPENCODE_MAJOR
  local CONTROL_RECORD_LOCKED=1 FM_COMPOSER_DIALOG_SINK result
  local POLL=${FM_CONTROL_POLL:-0.5} SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
  local ARM_WAIT=${FM_CONTROL_ARM_WAIT:-1.5} EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
  local EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3} VERB=exit
  STATE=${META%/*}
  local -x FM_HOME=${3:-$FM_HOME} FM_STATE_OVERRIDE=$STATE
  # shellcheck source=bin/fm-control-lib.sh
  . "$SCRIPT_DIR/fm-control-lib.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  # shellcheck source=bin/fm-timing-lib.sh
  . "$SCRIPT_DIR/fm-timing-lib.sh"
  die() { echo "error: $1; preserving endpoint, record and worktree lease" >&2; exit 1; }
  "$SCRIPT_DIR/fm-omnigent.sh" capture --record-locked "$META" || true
  "$SCRIPT_DIR/fm-omnigent.sh" retire --record-locked "$META" || die 'could not persist Omnigent retirement intent'
  result=$("$SCRIPT_DIR/fm-omnigent.sh" probe --fresh "$META")
  if [ "$result" != dead ]; then
    [ "$result" = alive ] || die "task $ID's Omnigent native owner is unknown"
    fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
    BACKEND=$FM_BACKEND_VALIDATED_BACKEND T=$FM_BACKEND_VALIDATED_TARGET
    LABEL="fm-$ID"
    HARNESS=$(fm_control_harness_family "$(fm_meta_get "$META" harness)") || die 'unverified exit harness'
    fm_control_harness_supported "$HARNESS" || die 'unverified exit harness'
    OPENCODE_MAJOR=$(fm_meta_get "$META" opencode_version)
    OPENCODE_MAJOR=${OPENCODE_MAJOR%%.*}
    # shellcheck disable=SC2034 # Read by the backend composer classifier.
    FM_COMPOSER_HARNESS=$HARNESS
    FM_COMPOSER_DIALOG_SINK=$STATE/$ID.composer-dialog
    trap 'rm -f "$FM_COMPOSER_DIALOG_SINK"' EXIT
    result=$(do_exit) || exit 1
  fi
  # Stop proof is established. Archive confirmation is history retirement only;
  # a failure warns but does not prevent release of the stopped owner's lease.
  "$SCRIPT_DIR/fm-omnigent.sh" archive --record-locked "$META" >/dev/null || true
)
