#!/usr/bin/env bash
# Behavior tests for the verified Kiro CLI crewmate/scout adapter, on both the
# V3 engine (the default) and the V2 engine config/kiro-engine can select.
#
# The facts pinned here are the ones a kiro release could silently change and
# the ones a wrong guess would make dangerous:
#   1. kiro publishes no harness-identity marker of its own (a live 2.21.4 tool
#      subprocess carries no KIRO_* identity; KIRO_HOME is a firstmate-set
#      config-relocation path), so detection is ancestry alone on the anchored
#      process name `kiro-cli`. As a markerless harness, kiro's comm-strength
#      ancestry outranks an inherited foreign CLAUDECODE (the marker-vs-ancestry
#      boundary fm-harness-precedence.test.sh owns), so a kiro crewmate is never
#      silently renamed to claude; the spawn still clears the marker as defense
#      in depth (asserted in the launch test).
#   2. kiro is claude-shaped: its V2 agent-config hooks (userPromptSubmit opens,
#      stop closes and keeps the turn-ended touch) are its ONLY busy source
#      (kiro-hook), scoped so they classify no other adapter, and a kiro task
#      with no record is unknown rather than pane-classified. The rendered
#      `Kiro is working` footer is a DELIVERY guard only. The hook commands
#      themselves are executed end to end in fm-busy-adapter-wiring.test.sh.
#   3. The turn-end hook config must never land in the worktree's own .kiro/:
#      the spawn writes a firstmate-owned per-task agent config under
#      state/<id>.kiro-home/agents/firstmate.json and reaches it by relocating
#      KIRO_HOME (since --agent is name-only), seeding
#      chat.disableTrustAllConfirmation into that home so --trust-all-tools does
#      not block on its modal. Teardown removes the whole per-task home. Because
#      the name also resolves from the worktree and the workspace copy wins, a
#      worktree that already defines a firstmate agent refuses the spawn rather
#      than launching a worker whose hooks another config has shadowed.
#   4. The launch carries the brief as a positional prompt on --agent-engine v2
#      with --agent, --trust-all-tools, --model, and --effort; a requested model
#      a reachable --list-models omits refuses loudly, while a hung, unreachable
#      or unreadable listing launches unvalidated instead. --effort passes the full
#      low|medium|high|xhigh|max vocabulary (unlike agy, which omits xhigh).
#   5. kiro is a crewmate/scout adapter only: a secondmate launch is refused.
#   6. config/kiro-engine selects the engine: absent means v3, v2 keeps every
#      V2 fact above, and any other value refuses before a pane exists. V3
#      resolves agents and hooks from the real $HOME/.kiro rather than
#      KIRO_HOME, so a V3 launch names no agent and writes no agent config;
#      it installs a firstmate-owned global hook pair under $HOME/.kiro/hooks
#      instead, registers this task through a token, and drops a git-excluded
#      .fm-kiro-hook pointer in the worktree. Teardown retires the token. The
#      dispatchers themselves are executed end to end in
#      fm-busy-adapter-wiring.test.sh. Cases 3-4 above run with v2 pinned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-kiro-harness)

# --- Detection --------------------------------------------------------------

test_kiro_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/user/.toolbox/bin/kiro-cli'; exit 0 ;;
  *"args="*) printf '%s\n' 'kiro-cli chat --agent-engine v2'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro ] \
    || fail "the kiro-cli command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects the kiro-cli command"
}

test_kiro_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=kiroctl FAKE_PS_ARGS='kiroctl --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kiro ] \
    || fail "an unrelated kiroctl command must not detect kiro, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo kiro-cli --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kiro ] \
    || fail "a later shell argument naming kiro-cli must not detect kiro, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated kiro mentions"
}

test_kiro_ancestry_outranks_inherited_claude_marker() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-marker")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'kiro-cli'; exit 0 ;;
  *"args="*) printf '%s\n' 'kiro-cli chat'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # kiro is markerless, so its comm-strength ancestry must outrank an inherited
  # foreign CLAUDECODE - a kiro crewmate under a claude primary is never renamed
  # to claude (the marker-vs-ancestry boundary in fm-harness-precedence.test.sh).
  # The spawn still clears the marker as defense in depth (launch test), but the
  # ancestry signal alone is enough here.
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro ] \
    || fail "a real kiro-cli ancestry must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: kiro's ancestry outranks an inherited CLAUDECODE (markerless harness)"
}

# --- Liveness ---------------------------------------------------------------

test_kiro_liveness_names_the_command_an_agent() {
  [ "$(fm_agent_process_classify_name /home/u/.toolbox/bin/kiro-cli)" = agent ] \
    || fail "the kiro-cli process name must classify as a live agent"
  [ "$(fm_agent_process_classify_name /usr/bin/kiroctl)" = other ] \
    || fail "an unrelated kiroctl process must not classify as a kiro agent"
  local install='/Users/test/Library/Application Support/kiro-cli' args name argv0
  args="$install/bun --no-env-file $install/tui.js chat --agent-engine v3"
  [ "$(fm_agent_process_classify_name bun "$install/bun" "$args")" = agent ] \
    || fail "Kiro V3's bundled bun and tui.js must identify an agent"
  [ "$(fm_agent_process_classify bun "$install/bun" "$args")" = agent ] \
    || fail "the shared classifier must forward Kiro V3 command-line evidence"
  [ "$(fm_agent_process_classify /Users/test/Libr /Users/test/Library/Application "$args")" = agent ] \
    || fail "Kiro paths containing spaces must survive truncated ps identity fields"
  for args in '/usr/bin/bun' '/usr/bin/bun /tmp/tui.js' \
    "$install/bun --no-env-file $install/tui.js.bak" \
    "$install/bun --no-env-file /tmp/tui.js" \
    "/usr/bin/bun /tmp/app.js $install/tui.js" \
    "/usr/bin/bun /tmp/app.js $install/bun --no-env-file /usr/bin/bun /tmp/app.js $install/tui.js"; do
    argv0=/usr/bin/bun
    case "$args" in "$install/bun "*) argv0="$install/bun" ;; esac
    [ "$(fm_agent_process_classify bun "$argv0" "$args")" = other ] \
      || fail "unrelated bun command must not identify an agent: $args"
  done
  for name in 'zsh (kiro-cli-term)' 'zsh (kiro-cli-t' 'zsh (kiro-cli-te'; do
    [ "$(fm_agent_process_classify_name "$name")" = shell ] \
      || fail "Kiro shell integration name must identify a shell: $name"
    [ "$(fm_agent_process_classify "$name" 'zsh (kiro-cli-term)' 'zsh (kiro-cli-term)')" = shell ] \
      || fail "both decorated shell identity fields must agree on shell"
  done
  [ "$(fm_agent_process_classify_name 'zsh (kiro-cli-task)')" = other ] \
    || fail "unverified Kiro-like shell titles must remain other"
  pass "fm-agent-process-lib: Kiro V2/V3 agents and decorated shells stay distinct"
}

# --- Control ----------------------------------------------------------------

test_kiro_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported kiro || fail "kiro must be a supported control harness"
  [ "$(fm_control_harness_family kiro)" = kiro ] || fail "kiro must resolve to its own family"
  [ "$(fm_control_interrupt_key kiro)" = Escape ] || fail "kiro interrupts on Escape"
  [ "$(fm_control_interrupt_repeat kiro)" = 1 ] || fail "kiro interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key kiro)" ] || fail "kiro needs no composer clear key"
  [ "$(fm_control_interrupt_ack_source kiro)" = none ] || fail "kiro's interrupt ack source is none"
  [ "$(fm_control_exit_command kiro)" = /quit ] || fail "kiro exits with /quit"
  fm_control_harness_supports_kind kiro crewmate || fail "kiro must run a crewmate"
  fm_control_harness_supports_kind kiro scout || fail "kiro must run a scout"
  fm_control_harness_supports_kind kiro secondmate && fail "kiro must refuse a secondmate" || true
  pass "fm-control-lib: kiro control mechanics are Escape / single / /quit, crewmate-scout only"
}

test_kiro_wiring_path_is_the_out_of_tree_hook_config() {
  local out expected
  out=$(fm_control_harness_wiring_paths kiro /wt /state kid)
  expected="/state/kid.kiro-home/agents/firstmate.json
/state/kid.kiro-home/hooks/user-prompt-submit
/state/kid.kiro-home/hooks/stop
/wt/.fm-kiro-hook"
  [ "$out" = "$expected" ] \
    || fail "kiro wiring must retire the per-task hook config, both hook scripts and the V3 pointer, got '$out'"
  # The V3 pointer is the only worktree-resident artifact.
  case "$(printf '%s\n' "$out" | grep -v '^/wt/.fm-kiro-hook$')" in
    */wt/*) fail "kiro wiring must not point inside the worktree beyond the V3 pointer" ;;
  esac
  [ "$(fm_control_harness_turnend_token_path kiro /state kid)" = /state/kid.kiro-hook-token ] \
    || fail "kiro's V3 registry token must be retired through the turn-end token path"
  [ "$(HOME=/h fm_control_harness_turnend_auth_path kiro fm.abcdefABCDEF)" = /h/.kiro/hooks/fm-kiro.d/fm.abcdefABCDEF ] \
    || fail "kiro's V3 registry entry must live under \$HOME/.kiro/hooks/fm-kiro.d"
  [ -z "$(HOME=/h fm_control_harness_turnend_auth_path kiro '../x')" ] \
    || fail "a malformed kiro token must resolve to no registry path"
  pass "fm-control-lib: kiro wiring paths are the out-of-tree hook config, its scripts, and the V3 pointer and token"
}

# --- Busy: the hook record is the only state source -------------------------

test_kiro_quota_is_its_own_provider() {
  # Kiro serves Claude models on Kiro credits, so its quota is quota-axi's own
  # kiro provider row, never the claude row.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-quota-axi-lib.sh"
    [ "$(fm_quota_provider_for_harness kiro)" = kiro ] || exit 1
    [ "$(fm_quota_single_provider_for_harness kiro)" = kiro ] || exit 2
  ) || fail "kiro must map to the kiro quota provider in both quota-axi tables"
  pass "fm-quota-axi-lib: kiro reads the kiro quota provider, not claude"
}

test_kiro_hook_is_the_trusted_primary_source() {
  fm_busy_source_trusted kiro kiro-hook || fail "kiro-hook must be trusted for kiro"
  fm_busy_source_trusted kiro claude-hook && fail "kiro must not trust another adapter's source" || true
  fm_busy_source_trusted claude kiro-hook && fail "claude must not trust kiro-hook" || true
  pass "fm-busy-lib: kiro-hook is kiro's trusted source and is scoped to kiro"
}

# kiro's real busy composer row, assembled at RUNTIME from byte escapes so no line
# of this file is itself a form the delivery union matches. That matters most here:
# the fleet's own crewmates work in this repository, so a pane showing grep output,
# a pager, an editor buffer or a printed failure from this file would otherwise
# carry a live acknowledgement token and let an undelivered steer read as landed.
# The separator is kiro's theme glyph, U+00B7 by default and an ASCII period under
# the ASCII theme; the mode hint is `Type to steer` in STEER interrupt mode and
# `Type to queue` otherwise.
kiro_busy_row() {  # [dot|ascii] [steer|queue]
  local theme=${1:-dot} mode=${2:-steer} sep
  case "$theme" in
    ascii) sep='.' ;;
    *) sep=$(printf '\302\267') ;;
  esac
  case "$mode" in
    queue) printf '\342\200\272 Kiro is working %s Type to queue %s Ctrl+S to steer' "$sep" "$sep" ;;
    *) printf '\342\200\272 Kiro is working %s Type to steer %s Ctrl+S to queue' "$sep" "$sep" ;;
  esac
}

# The hook record is kiro's only state source: it wins over a contradicting
# pane, and with no record the classifier reports unknown rather than reading
# the rendered footer.
test_kiro_record_is_the_only_state_source() {
  local state id busy_pane verdict
  state="$TMP_ROOT/busy-state"
  mkdir -p "$state"
  id=kiro-busy-1
  busy_pane=$'some output\n'"$(kiro_busy_row dot steer)"

  # A valid idle kiro-hook record must win even when the pane still renders the
  # busy footer (the record survives a misleading pane).
  printf 'g1\n' > "$state/$id.busy-gen"
  printf 'v1 gen=g1 seq=1 state=idle source=kiro-hook event=stop ts=1\n' > "$state/$id.busy-state"
  verdict=$(fm_busy_classify tmux fake-target kiro "$id" "$state" "$busy_pane")
  [ "$verdict" = "idle kiro-hook" ] \
    || fail "a valid idle kiro-hook record must win over a busy pane, got '$verdict'"

  # With the record gone, the busy footer must NOT classify: kiro has no pane
  # arm, so the verdict is unknown missing either way.
  rm -f "$state/$id.busy-state" "$state/$id.busy-gen"
  verdict=$(fm_busy_classify tmux fake-target kiro "$id" "$state" "$busy_pane")
  [ "$verdict" = "unknown missing" ] \
    || fail "a busy kiro footer must not classify with no record, got '$verdict'"
  verdict=$(fm_busy_classify tmux fake-target kiro "$id" "$state" $'idle chatter\n› ask a question or describe a task')
  [ "$verdict" = "unknown missing" ] \
    || fail "an idle kiro pane with no record must be unknown missing, got '$verdict'"

  # A record from a superseded incarnation is unknown, never a pane verdict.
  printf 'g2\n' > "$state/$id.busy-gen"
  printf 'v1 gen=g1 seq=1 state=busy source=kiro-hook event=user-prompt-submit ts=1\n' > "$state/$id.busy-state"
  verdict=$(fm_busy_classify tmux fake-target kiro "$id" "$state" "$busy_pane")
  [ "$verdict" = "unknown gen-mismatch" ] \
    || fail "a stale-gen kiro record must be unknown gen-mismatch, got '$verdict'"
  pass "fm-busy-lib: the kiro-hook record is kiro's only state source; no record is unknown"
}

# --- Composer ---------------------------------------------------------------

test_kiro_composer_glyph_and_placeholder() {
  local esc caps caps_plain row screen plain state stripped
  esc=$(printf '\033')
  caps=$'styled=1\ncursor=1\nidentity=1\nrows=0'
  caps_plain=$'styled=0\nrows=6'
  # kiro's bare `›` composer (shared glyph with codex) is a genuine empty
  # composer.
  state=$(fm_composer_classify_screen "$caps" $'transcript line\n›  ' 1)
  [ "$state" = empty ] || fail "a bare kiro › composer must read empty, got '$state'"

  # kiro's REAL idle composer row: a bright `›` glyph, then the placeholder and
  # a `↵` submit hint, both drawn in truecolor near-gray 38;2;158;158;158.
  # That colour and its 256-colour encoding below were measured on kiro-cli
  # 2.21.5 on macOS; the rest of this file's vendor facts come from the
  # 2.21.4 Amazon Linux 2 verification (docs/verification/kiro.md).
  # Luminance 158 clears the shared 128 ghost ceiling, so
  # only the near-achromatic ceiling strips this row - keep the colour as the
  # tool renders it so removing that ceiling turns this case red.
  row="› ${esc}[38;2;158;158;158mask a question or describe a task ↵${esc}[0m"
  screen=$'transcript line\n'"$row"
  plain=$'transcript line\n›  ask a question or describe a task ↵'

  # NON-VACUOUSNESS: on a styled capture the near-gray placeholder is ghost
  # text, so the row reduces to the bare glyph, which decides the verdict.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = '›' ] \
    || fail "kiro's near-gray placeholder must strip to the bare glyph, got '$stripped'"
  state=$(fm_composer_classify_screen "$caps" "$screen" 1)
  [ "$state" = empty ] || fail "kiro's styled idle row must read empty, got '$state'"

  # The SAME idle row on a pane whose terminal advertises no truecolor: kiro
  # draws the placeholder as 256-colour 38;5;247, xterm grey level 158, the
  # identical grey. This row read `pending` while only truecolour was tested, so
  # every steer to that worker was skipped forever.
  row="› ${esc}[38;5;247mask a question or describe a task ↵${esc}[0m"
  screen=$'transcript line\n'"$row"
  state=$(fm_composer_classify_screen "$caps" "$screen" 1)
  [ "$state" = empty ] \
    || fail "kiro's 256-colour idle row must read empty, never pending, got '$state'"

  # An UNSTYLED capture cannot ghost-strip, so the bare-row path degrades any
  # trailing text to `unknown` rather than a false `pending`.
  state=$(fm_composer_classify_screen "$caps_plain" "$plain")
  [ "$state" = unknown ] \
    || fail "kiro's unstyled idle row must read unknown, never pending, got '$state'"
  pass "fm-composer-lib: kiro's › composer is empty and its real idle row is empty styled, unknown plain"
}

test_kiro_delivery_footer_matches_and_is_scoped() {
  # The harness-less union is the ONE path that decides a kiro delivery:
  # fm_tmux_submit_core classifies with no harness, so this is the matcher a
  # landed kiro submit is read by.
  printf '%s\0' $'work\n'"$(kiro_busy_row dot steer)" | fm_busy_lines_match \
    || fail "the harness-less delivery union must see kiro's STEER-mode busy footer"
  # kiro's DEFAULT interrupt mode renders `Type to queue` where STEER renders
  # `Type to steer`, and its spec-task run renders a third variant, so the union
  # anchors on what all three share and must not depend on the mode hint.
  printf '%s\0' $'work\n'"$(kiro_busy_row dot queue)" | fm_busy_lines_match \
    || fail "the union must see kiro's default-mode busy footer, not only the STEER one"
  # The separator is a theme glyph with two values, so both must acknowledge.
  printf '%s\0' $'work\n'"$(kiro_busy_row ascii queue)" | fm_busy_lines_match \
    || fail "the union must see kiro's busy footer under its ASCII separator theme"
  printf '%s\0' $'idle\n› ask a question or describe a task' | fm_busy_lines_match \
    && fail "kiro's idle placeholder row must not read as a busy footer" || true
  # The union requires the separator, so worker output that merely names the phrase
  # - prose about kiro, quoted or grepped onto a pane - cannot acknowledge a submit
  # that never landed.
  printf '%s\0' $'the busy row opens with `Kiro is working`, then a separator' | fm_busy_lines_match \
    && fail "prose naming the bare Kiro is working phrase must not read as a busy footer" || true
  # kiro declares no harness-scoped signature, so a caller that does pass
  # harness=kiro falls to the fail-closed arm rather than borrowing another
  # harness's footer.
  printf '%s\0' $'work\n'"$(kiro_busy_row dot steer)" | fm_busy_lines_match kiro \
    && fail "harness=kiro must classify nothing busy; kiro declares no scoped signature" || true
  pass "fm-composer-lib: the harness-less union sees kiro's busy footer in every mode and separator, not its idle row or prose naming the phrase, and harness=kiro is fail-closed"
}

# --- Spawn (real fm-spawn driven by a fake tmux) ----------------------------

make_kiro_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '4\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    literal=; prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    # A spawn types a short line sourcing its staged launch file (#4994); log
    # the staged command itself so the assertions see what the pane runs.
    case "$literal" in
      ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
    esac
    case "$literal" in
      *"--agent-engine "*) printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG" ;;
    esac
    exit 0
    ;;
  capture-pane)
    # A settled, idle kiro composer so any readiness read sees a ready pane.
    printf 'fmt · auto · 2%%\n›  ask a question or describe a task\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/kiro-cli" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_KIRO_ARGS_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KIRO_ARGS_LOG"
case "$*" in
  *"--list-models"*)
    if [ "${FM_FAKE_KIRO_MODELS_FAIL:-0}" = 1 ]; then exit 3; fi
    if [ "${FM_FAKE_KIRO_MODELS_HANG:-0}" = 1 ]; then cat > /dev/null; sleep 30; exit 0; fi
    # A reachable listing whose id field kiro has renamed, so no model_id parses.
    if [ "${FM_FAKE_KIRO_MODELS_RENAMED:-0}" = 1 ]; then
      printf '%s' '{"models":[{"id":"auto"},{"id":"claude-opus-5"}],"default_model":"auto"}'
      exit 0
    fi
    # -f json is free to pretty-print, so both shapes must yield model ids.
    if [ "${FM_FAKE_KIRO_MODELS_PRETTY:-0}" = 1 ]; then
      cat <<'JSON'
{
  "models": [
    { "model_id": "auto" },
    { "model_id": "claude-opus-5" },
    { "model_id": "claude-sonnet-5" }
  ],
  "default_model": "auto"
}
JSON
      exit 0
    fi
    printf '%s' '{"models":[{"model_id":"auto"},{"model_id":"claude-opus-5"},{"model_id":"claude-sonnet-5"}],"default_model":"auto"}'
    exit 0
    ;;
esac
echo "fake kiro-cli must never run a chat turn" >&2
exit 9
SH
  chmod +x "$fakebin/kiro-cli"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_kiro_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_kiro_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Kiro dispatch.

## Firstmate spec
Verify launch and hook wiring.
EOF
  printf 'kiro\n' > "$home/config/crew-harness"
  # Most cases pin the V2 engine they were written against; KIRO_TEST_ENGINE
  # names another token, or `absent` to leave config/kiro-engine unset (v3).
  case "${KIRO_TEST_ENGINE:-v2}" in
    absent) ;;
    *) printf '%s\n' "${KIRO_TEST_ENGINE:-v2}" > "$home/config/kiro-engine" ;;
  esac
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_kiro_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_kiro_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="${FM_TEST_STATE_OVERRIDE:-$home/state}" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_KIRO_MODELS_FAIL="${FM_FAKE_KIRO_MODELS_FAIL:-0}" \
    FM_FAKE_KIRO_MODELS_HANG="${FM_FAKE_KIRO_MODELS_HANG:-0}" \
    FM_FAKE_KIRO_MODELS_PRETTY="${FM_FAKE_KIRO_MODELS_PRETTY:-0}" \
    FM_FAKE_KIRO_MODELS_RENAMED="${FM_FAKE_KIRO_MODELS_RENAMED:-0}" \
    FM_FAKE_KIRO_ARGS_LOG="$case_dir/kiro-args.log" \
    FM_KIRO_MODELS_TIMEOUT="${FM_KIRO_MODELS_TIMEOUT:-1}" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kiro --mode no-mistakes --yolo off "$@" 2>&1
}

test_kiro_launch_carries_brief_agent_engine_and_clears_markers() {
  local id rec out rc launch meta home_dir
  id="kiro-launch-z1-$$"
  rec=$(make_kiro_spawn_case launch "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model claude-opus-5 --effort high)
  rc=$?
  expect_code 0 "$rc" "kiro spawn with a listed model should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/kiro-cli" "kiro launch did not pin the resolved absolute binary"
  assert_contains "$launch" "chat --agent-engine v2" "kiro launch did not pin the V2 engine"
  assert_contains "$launch" "--agent firstmate" "kiro launch did not name the per-task agent"
  assert_contains "$launch" "--trust-all-tools" "kiro launch omitted --trust-all-tools"
  assert_contains "$launch" "--model 'claude-opus-5'" "kiro launch did not carry the requested model"
  assert_contains "$launch" "--effort 'high'" "kiro launch did not carry the requested effort"
  assert_contains "$launch" "KIRO_HOME=" "kiro launch did not relocate KIRO_HOME"
  assert_contains "$launch" "$HOME_DIR/state/$id.kiro-home" "kiro launch did not relocate KIRO_HOME to the per-task home"
  assert_contains "$launch" "env -u CLAUDECODE" "kiro launch did not clear the inherited launcher marker"
  assert_not_contains "$launch" "__KIROBIN__" "kiro launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__KIROHOME__" "kiro launch left its home placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "kiro launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "kiro launch left its brief placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=kiro' "$meta" "kiro meta did not record its harness"
  assert_grep 'model=claude-opus-5' "$meta" "kiro meta did not record its model"
  assert_grep 'effort=high' "$meta" "kiro meta did not record its effort"
  pass "fm-spawn: kiro launch carries brief, V2 engine, agent, model, effort with cleared markers"
}

test_kiro_v3_is_the_default_engine_and_names_no_agent() {
  local id rec out rc launch
  id="kiro-v3-launch-z11-$$"
  rec=$(KIRO_TEST_ENGINE=absent make_kiro_spawn_case v3launch "$id")
  read_kiro_spawn_record "$rec"
  [ ! -e "$HOME_DIR/config/kiro-engine" ] || fail "the default case must leave config/kiro-engine absent"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model claude-opus-5 --effort max)
  rc=$?
  expect_code 0 "$rc" "a default-engine kiro spawn should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/kiro-cli" "kiro V3 launch did not pin the resolved absolute binary"
  assert_contains "$launch" "chat --agent-engine v3 " "an absent config/kiro-engine must launch the V3 engine"
  assert_not_contains "$launch" "--agent-engine v2" "a V3 launch must not also carry the V2 engine"
  assert_not_contains "$launch" "--agent firstmate" "V3 reads no agent from KIRO_HOME, so the launch must name none"
  assert_not_contains "$launch" "__KIRO" "kiro V3 launch left a kiro placeholder unsubstituted"
  assert_contains "$launch" "--trust-all-tools" "kiro V3 launch omitted --trust-all-tools"
  assert_contains "$launch" "--model 'claude-opus-5'" "kiro V3 launch did not carry the requested model"
  assert_contains "$launch" "--effort 'max'" "kiro V3 launch did not carry the requested effort"
  assert_contains "$launch" "KIRO_HOME=" "kiro V3 launch did not relocate KIRO_HOME"
  assert_contains "$launch" "$HOME_DIR/state/$id.kiro-home" "kiro V3 launch did not relocate KIRO_HOME to the per-task home"
  assert_contains "$launch" "env -u CLAUDECODE" "kiro V3 launch did not clear the inherited launcher marker"
  # The model check asks the same engine the worker will run.
  assert_grep 'chat --agent-engine v3 --list-models -f json' "$CASE_DIR/kiro-args.log" \
    "the V3 model check did not list the V3 catalog"
  pass "fm-spawn: an absent config/kiro-engine launches V3 with no agent name, validating against the V3 catalog"
}

test_kiro_v3_installs_the_guarded_global_hook_pair() {
  local id rec out rc user_home hooks home_dir token trigger cmd
  id="kiro-v3-hooks-z12-$$"
  rec=$(KIRO_TEST_ENGINE=v3 make_kiro_spawn_case v3hooks "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a V3 kiro spawn should succeed: $out"
  user_home=$HOME_DIR
  hooks="$user_home/.kiro/hooks"
  home_dir="$HOME_DIR/state/$id.kiro-home"
  # Both engines share the per-task scripts and the trust setting.
  [ -x "$home_dir/hooks/user-prompt-submit" ] || fail "V3 spawn did not write the per-task open script"
  [ -x "$home_dir/hooks/stop" ] || fail "V3 spawn did not write the per-task close script"
  [ "$(jq -r '.["chat.disableTrustAllConfirmation"]' "$home_dir/settings/cli.json")" = true ] \
    || fail "the kiro V3 trust modal is not suppressed"
  [ ! -e "$home_dir/agents/firstmate.json" ] || fail "V3 must not write an agent config it would never read"
  [ ! -e "$WT_DIR/.kiro" ] || fail "V3 spawn wrote into the worktree's own .kiro/"
  # The global pair is the V3-consumed contract, parsed as JSON.
  jq -e '.version == "v1"' "$hooks/firstmate-crew.json" >/dev/null \
    || fail "the V3 global hook file is not a v1 hook document"
  for trigger in UserPromptSubmit Stop; do
    cmd=$(jq -r --arg t "$trigger" '[.hooks[] | select(.trigger == $t)] | if length == 1 then .[0].action.command else empty end' "$hooks/firstmate-crew.json")
    [ -n "$cmd" ] || fail "the V3 global hook file must carry exactly one $trigger hook"
    [ "$cmd" = "${cmd%%[[:space:]]*}" ] || fail "the V3 $trigger command must be a single token, got '$cmd'"
    [ -x "$cmd" ] || fail "the V3 $trigger command is not an executable file: '$cmd'"
    case "$cmd" in "$hooks"/*) ;; *) fail "the V3 $trigger dispatcher must live beside the hook file, got '$cmd'" ;; esac
  done
  # The task is registered by token: the worktree pointer names it, the
  # registry entry names this task's kiro home, and state keeps it for retirement.
  token=$(cat "$HOME_DIR/state/$id.kiro-hook-token")
  case "$token" in fm.????????????) ;; *) fail "the V3 registry token is malformed: '$token'" ;; esac
  [ "$(cat "$WT_DIR/.fm-kiro-hook")" = "token=$token" ] || fail "the worktree pointer does not name the task token"
  [ "$(cat "$hooks/fm-kiro.d/$token")" = "$(cd "$HOME_DIR/state" && pwd -P)/$id.kiro-home" ] \
    || fail "the registry entry does not name this task's kiro home"
  [ -z "$(git -C "$WT_DIR" status --porcelain -- .fm-kiro-hook)" ] \
    || fail "the V3 pointer must be git-excluded, never an untracked file a worker could commit"
  # Nothing else in the captain's ~/.kiro is written.
  [ "$(cd "$user_home/.kiro" && find . -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')" = "./hooks " ] \
    || fail "a V3 spawn must write only ~/.kiro/hooks"

  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  rc=$?
  expect_code 0 "$rc" "V3 kiro teardown should succeed: $out"
  [ ! -e "$hooks/fm-kiro.d/$token" ] || fail "teardown left the V3 registry entry behind"
  [ ! -e "$HOME_DIR/state/$id.kiro-hook-token" ] || fail "teardown left the V3 registry token behind"
  [ ! -e "$home_dir" ] || fail "teardown left the per-task kiro home behind"
  [ -f "$hooks/firstmate-crew.json" ] || fail "teardown must keep the shared global pair for other tasks"
  pass "fm-spawn: a V3 kiro spawn installs the guarded global hook pair and a token pointer that teardown retires"
}

test_kiro_engine_config_refuses_unknown_values() {
  local id rec out rc
  id="kiro-engine-bad-z13-$$"
  rec=$(KIRO_TEST_ENGINE=v9 make_kiro_spawn_case badengine "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown config/kiro-engine must refuse the spawn"
  assert_contains "$out" "config/kiro-engine holds 'v9'" "the refusal did not name the offending value"
  assert_contains "$out" "v3 (the default when the file is absent), v2" "the refusal did not name the accepted values"
  [ -s "$CASE_DIR/launch.log" ] && fail "an unknown engine created a launch command" || true
  [ ! -e "$HOME_DIR/state/$id.kiro-home" ] || fail "an unknown engine still armed the per-task home"
  pass "fm-spawn: an unknown config/kiro-engine refuses before any pane is created"
}

test_kiro_per_task_hook_config_is_out_of_tree() {
  local id rec out rc home_dir agent settings trigger cmd
  id="kiro-hooks-z2-$$"
  rec=$(make_kiro_spawn_case hooks "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "kiro spawn should succeed: $out"
  home_dir="$HOME_DIR/state/$id.kiro-home"
  agent="$home_dir/agents/firstmate.json"
  settings="$home_dir/settings/cli.json"
  [ -f "$agent" ] || fail "kiro spawn did not write the per-task agent config"
  [ -f "$settings" ] || fail "kiro spawn did not seed the per-task trust setting"
  # The emitted config is the kiro-consumed contract, so it is parsed as JSON,
  # never grepped. Each hook command must be a runnable single-token path under
  # the per-task home, which is what makes the hooks work whether kiro shells out
  # or splits argv. What those scripts DO is executed end to end in
  # tests/fm-busy-adapter-wiring.test.sh.
  jq -e . "$agent" >/dev/null || fail "the kiro agent config is not valid JSON"
  for trigger in userPromptSubmit stop; do
    cmd=$(jq -r ".hooks[\"$trigger\"][0].command" "$agent")
    [ -n "$cmd" ] && [ "$cmd" != null ] \
      || fail "the kiro agent config lacks the $trigger hook command"
    [ "$cmd" = "${cmd%%[[:space:]]*}" ] \
      || fail "the kiro $trigger hook command must be a single token, got '$cmd'"
    [ -x "$cmd" ] || fail "the kiro $trigger hook command is not an executable file: '$cmd'"
    case "$cmd" in
      "$home_dir"/*) ;;
      *) fail "the kiro $trigger hook script must live under the per-task home, got '$cmd'" ;;
    esac
  done
  [ "$(jq -r '.["chat.disableTrustAllConfirmation"]' "$settings")" = true ] \
    || fail "the kiro trust modal is not suppressed"
  # The pivotal element-3 guarantee: nothing is written into the disposable
  # worktree's own .kiro/.
  [ ! -e "$WT_DIR/.kiro" ] || fail "kiro spawn wrote into the worktree's own .kiro/ (must stay out of tree)"
  # The busy generation is armed and embedded in the hook.
  [ -e "$HOME_DIR/state/$id.busy-gen" ] || fail "kiro spawn did not arm a busy generation"
  pass "fm-spawn: kiro writes an out-of-tree per-task hook config and trust setting, never the worktree's .kiro/"
}

test_kiro_effort_xhigh_passes_through() {
  local id rec out rc launch
  id="kiro-xhigh-z3-$$"
  rec=$(make_kiro_spawn_case xhigh "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "kiro spawn with xhigh should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--effort 'xhigh'" "kiro must pass xhigh through (unlike agy)"
  pass "fm-spawn: kiro passes the full effort vocabulary including xhigh"
}

test_kiro_unlisted_model_refuses_before_pane_creation() {
  local id rec out rc
  id="kiro-badmodel-z4-$$"
  rec=$(make_kiro_spawn_case badmodel "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model no-such-model)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted kiro model must refuse the spawn"
  assert_contains "$out" "not listed by 'kiro-cli --list-models'" "the refusal did not name the model check"
  [ -s "$CASE_DIR/launch.log" ] && fail "an unlisted model created a launch command" || true
  pass "fm-spawn: an unlisted kiro model refuses before any pane is created"
}

# Every other spawn case runs under a whitespace-free temporary root, so the
# single-token assertions above cannot see the one path shape that breaks the
# hooks under both a shell and an argv split.
test_kiro_whitespace_hook_path_refuses_before_pane_creation() {
  local id rec out rc spaced spaced_real
  id="kiro-space-z10-$$"
  rec=$(make_kiro_spawn_case spaced "$id")
  read_kiro_spawn_record "$rec"
  spaced="$CASE_DIR/spaced state"
  mkdir -p "$spaced"
  cp "$HOME_DIR/state/.last-watcher-beat" "$spaced/.last-watcher-beat"
  spaced_real=$(cd "$spaced" && pwd -P)
  out=$(FM_TEST_STATE_OVERRIDE="$spaced" \
    run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a kiro hook path containing whitespace must refuse the spawn"
  assert_contains "$out" "$spaced_real/$id.kiro-home" "the refusal did not name the offending hook path"
  [ ! -e "$spaced/$id.kiro-home" ] || fail "the refused spawn still armed the per-task home"
  [ -s "$CASE_DIR/launch.log" ] && fail "a whitespace hook path created a launch command" || true
  pass "fm-spawn: a kiro hook path containing whitespace refuses before any pane is created"
}

# --agent is name-only and the workspace copy wins the name collision, so a
# project that ships its own firstmate agent leaves the launched worker with no
# hooks and a busy record nothing can close.
test_kiro_workspace_agent_collision_refuses_before_pane_creation() {
  local id rec out rc shadow
  id="kiro-shadow-z11-$$"
  rec=$(make_kiro_spawn_case shadow "$id")
  read_kiro_spawn_record "$rec"
  # The project SHIPS the colliding config, which is the real shape: it reaches the
  # pooled worktree through the base refresh and leaves that worktree clean, where
  # an untracked copy would be refused earlier as uncommitted work.
  mkdir -p "$PROJ_DIR/.kiro/agents"
  printf '%s\n' '{"name":"firstmate","description":"a target repo shipping its own firstmate agent","tools":["*"]}' \
    > "$PROJ_DIR/.kiro/agents/firstmate.json"
  git -C "$PROJ_DIR" add .kiro/agents/firstmate.json \
    || fail "could not stage the shipped agent config"
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'ship a firstmate agent config' \
    || fail "could not commit the shipped agent config"
  git -C "$PROJ_DIR" push -q origin main \
    || fail "could not publish the shipped agent config to origin"
  shadow="$WT_DIR/.kiro/agents/firstmate.json"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ -f "$shadow" ] || fail "the base refresh did not bring the shipped agent config into the worktree"
  [ "$rc" -ne 0 ] || fail "a worktree agent config named firstmate must refuse the spawn"
  assert_contains "$out" "$shadow" "the refusal did not name the shadowing agent config"
  [ ! -e "$HOME_DIR/state/$id.kiro-home" ] || fail "the refused spawn still armed the per-task home"
  [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "the refused spawn still armed a busy generation"
  [ -s "$CASE_DIR/launch.log" ] && fail "a shadowed agent name created a launch command" || true
  pass "fm-spawn: a worktree agent config named firstmate refuses before any pane is created"
}

# `-f json` is free to pretty-print, so the model check must read ids from a
# whitespaced listing too. Without that a valid model would hit the refusal
# branch and no kiro spawn could carry --model at all.
test_kiro_pretty_printed_listing_validates_the_model() {
  local id rec out rc launch
  id="kiro-pretty-z9-$$"
  rec=$(make_kiro_spawn_case pretty "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_MODELS_PRETTY=1 \
    run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model claude-opus-5)
  rc=$?
  expect_code 0 "$rc" "a pretty-printed listing must still validate a listed model: $out"
  assert_not_contains "$out" "not listed by" "a pretty-printed listing refused a listed model"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--model 'claude-opus-5'" "the pretty-printed case did not carry the model"

  # And it must still REFUSE an unlisted id rather than accept everything.
  id="kiro-prettybad-z10-$$"
  rec=$(make_kiro_spawn_case prettybad "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_MODELS_PRETTY=1 \
    run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model no-such-model)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a pretty-printed listing must still refuse an unlisted model"
  assert_contains "$out" "not listed by 'kiro-cli --list-models'" "the refusal did not name the model check"
  pass "fm-spawn: a pretty-printed kiro listing validates listed models and refuses unlisted ones"
}

# A reachable listing whose model_id fields cannot be read establishes nothing
# about whether the model exists, so it must take the unvalidated-launch path
# rather than refuse. Refusing would break every kiro --model spawn the day kiro
# renames the field or an account's catalog comes back empty.
test_kiro_unparseable_listing_launches_unvalidated() {
  local id rec out rc
  id="kiro-renamed-z11-$$"
  rec=$(make_kiro_spawn_case renamed "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_MODELS_RENAMED=1 \
    run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model claude-opus-5)
  rc=$?
  expect_code 0 "$rc" "a listing with no readable model_id must launch unvalidated: $out"
  assert_not_contains "$out" "not listed by" "an unreadable listing claimed the model is absent"
  assert_contains "$out" "carries no model_id" "an unreadable listing launched without its notice"
  [ -s "$CASE_DIR/launch.log" ] || fail "an unreadable listing produced no launch command"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'claude-opus-5'" \
    "the unvalidated launch dropped the requested model"
  pass "fm-spawn: a kiro listing with no readable model_id establishes nothing and launches"
}

test_kiro_unreachable_listing_launches_unvalidated() {
  local id rec out rc
  id="kiro-unreach-z5-$$"
  rec=$(make_kiro_spawn_case unreach "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_MODELS_FAIL=1 run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model claude-opus-5)
  rc=$?
  expect_code 0 "$rc" "an unreachable listing must launch unvalidated: $out"
  assert_contains "$out" "listing is unreachable" "an unreachable listing launched without its notice"
  [ -s "$CASE_DIR/launch.log" ] || fail "an unreachable listing produced no launch command"
  pass "fm-spawn: an unreachable kiro listing establishes nothing and launches"
}

test_kiro_hung_listing_is_cut_off_and_launches() {
  local id rec out rc
  id="kiro-hung-z6-$$"
  rec=$(make_kiro_spawn_case hung "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_MODELS_HANG=1 FM_KIRO_MODELS_TIMEOUT=1 \
    run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model claude-opus-5)
  rc=$?
  expect_code 0 "$rc" "a hung listing must be cut off and launch: $out"
  assert_contains "$out" "did not answer within 1s" "a hung listing launched without its timeout notice"
  [ -s "$CASE_DIR/launch.log" ] || fail "a hung listing produced no launch command"
  pass "fm-spawn: a hung kiro listing is cut off and launches unvalidated"
}

test_kiro_secondmate_is_refused() {
  local id rec out rc
  id="kiro-sm-z7-$$"
  rec=$(make_kiro_spawn_case secondmate "$id")
  read_kiro_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate kiro 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a kiro secondmate launch must be refused"
  assert_contains "$out" "kiro is a verified crewmate/scout adapter only" \
    "the secondmate refusal did not name the reason"
  pass "fm-spawn: a kiro secondmate launch is refused"
}

test_kiro_teardown_removes_the_per_task_home() {
  local id rec out rc home_dir
  id="kiro-teardown-z8-$$"
  rec=$(make_kiro_spawn_case teardown "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "kiro spawn should succeed before teardown: $out"
  home_dir="$HOME_DIR/state/$id.kiro-home"
  [ -d "$home_dir" ] || fail "the per-task home should exist after spawn"
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  rc=$?
  expect_code 0 "$rc" "kiro teardown should succeed: $out"
  [ ! -e "$home_dir" ] || fail "teardown left the per-task kiro home behind"
  pass "fm-teardown: kiro's per-task home is removed on teardown"
}

test_kiro_ancestry_detects_the_native_command_name
test_kiro_ancestry_rejects_unrelated_mentions
test_kiro_ancestry_outranks_inherited_claude_marker
test_kiro_liveness_names_the_command_an_agent
test_kiro_control_mechanics_are_the_verified_ones
test_kiro_wiring_path_is_the_out_of_tree_hook_config
test_kiro_quota_is_its_own_provider
test_kiro_hook_is_the_trusted_primary_source
test_kiro_record_is_the_only_state_source
test_kiro_composer_glyph_and_placeholder
test_kiro_delivery_footer_matches_and_is_scoped
test_kiro_launch_carries_brief_agent_engine_and_clears_markers
test_kiro_v3_is_the_default_engine_and_names_no_agent
test_kiro_v3_installs_the_guarded_global_hook_pair
test_kiro_engine_config_refuses_unknown_values
test_kiro_per_task_hook_config_is_out_of_tree
test_kiro_effort_xhigh_passes_through
test_kiro_unlisted_model_refuses_before_pane_creation
test_kiro_whitespace_hook_path_refuses_before_pane_creation
test_kiro_workspace_agent_collision_refuses_before_pane_creation
test_kiro_pretty_printed_listing_validates_the_model
test_kiro_unparseable_listing_launches_unvalidated
test_kiro_unreachable_listing_launches_unvalidated
test_kiro_hung_listing_is_cut_off_and_launches
test_kiro_secondmate_is_refused
test_kiro_teardown_removes_the_per_task_home
