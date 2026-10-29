#!/usr/bin/env bash
# Account reporting and deterministic Claude selection, with no credentials.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-accounts)
export HOME="$TMP_ROOT/home"
export FM_HOME="$TMP_ROOT/firstmate" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects"
mkdir -p "$HOME/workspace/guidex/app" "$HOME/workspace/other" "$HOME/.claude_b" "$TMP_ROOT/projects" "$TMP_ROOT/tools"
ln -s "$HOME/workspace/guidex/app" "$TMP_ROOT/projects/guidex_app"
TOOL="$ROOT/bin/fm-claude-accounts.sh"
SNAPSHOT="$TMP_ROOT/quota.json"

fixture() { # personal weekly, GuideX weekly, personal all_models, GuideX all_models
  jq -n --argjson p "$1" --argjson g "$2" --argjson pa "${3:-70}" --argjson ga "${4:-70}" '
    def row($key; $weekly; $all):
      {provider:"claude", accountKey:$key, state:{status:"fresh"},
       windows:[{id:"model:fable",kind:"model",windowSeconds:604800,percentRemaining:$weekly}],
       quotaSemantics:{status:"known",effectiveAvailability:[
         {scope:"all_models",status:"known",effectivePercentRemaining:$all,runway:{status:"through_reset"},selection:{spendPriority:1}},
         {scope:"model:fable",status:"known",effectivePercentRemaining:([$weekly,$all]|min),runway:{status:"through_reset"},selection:{spendPriority:1}}
       ]}};
    {schemaVersion:6,providers:[row("claude-home";$p;$pa),row("claude-guidex";$g;$ga)]}' > "$SNAPSHOT"
}
select_account() {
  env -u CLAUDE_CONFIG_DIR FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" \
    bash "$TOOL" --snapshot "$SNAPSHOT" --project "$1" --model "$2" --dry-run
}
expect_account() {
  local label=$1 project=$2 model=$3 expected=$4 out
  out=$(select_account "$project" "$model") || fail "$label refused: $out"
  assert_contains "$out" "account: $expected" "$label"
  printf '%s -> %s\n' "$label" "$expected"
}
fixture 65 30
expect_account 'GuideX non-Fable' "$HOME/workspace/guidex/app" sonnet claude-guidex
expect_account 'registered GuideX symlink' projects/guidex_app opus claude-guidex
expect_account 'non-GuideX non-Fable' "$HOME/workspace/other" sonnet claude-home
expect_account 'Fable personal ahead, GuideX repo' projects/guidex_app claude-fable-5-1 claude-home
fixture 15 80
expect_account 'Fable GuideX ahead, personal repo' "$HOME/workspace/other" fable claude-guidex
fixture 80 20 39 10
expect_account 'personal floor removes the larger allowance' "$HOME/workspace/other" fable claude-guidex
fixture 80 20 40 10
expect_account 'personal floor includes exactly 40%' "$HOME/workspace/other" fable claude-home
fixture 80 60 40 90
expect_account 'raw weekly allowance wins over session headroom' "$HOME/workspace/other" fable claude-home
fixture 50 50
expect_account 'equal allowance uses repository account' projects/guidex_app fable claude-guidex
fixture 0 0
if out=$(select_account projects/guidex_app fable); then fail 'both exhausted selected an account'; fi
assert_contains "$out" 'account: unavailable' 'both exhausted request dispatch fallback'
printf 'Fable both exhausted -> dispatch fallback\n'
fixture 60 50
jq 'del(.providers[].windows)' "$SNAPSHOT" > "$TMP_ROOT/unknown.json"
mv "$TMP_ROOT/unknown.json" "$SNAPSHOT"
if out=$(select_account projects/guidex_app fable); then fail 'missing weekly evidence selected an account'; fi
assert_contains "$out" 'account: unknown' 'missing weekly evidence stays unknown'
for scope in all_models model:fable; do
  fixture 60 50
  jq --arg scope "$scope" '.providers[].quotaSemantics |= (.status="partial" |
    .effectiveAvailability |= map(if .scope == $scope then {scope:.scope,status:"unknown"} else . end))' "$SNAPSHOT" > "$TMP_ROOT/partial.json"
  mv "$TMP_ROOT/partial.json" "$SNAPSHOT"
  if out=$(select_account projects/guidex_app fable); then fail 'partial evidence selected an account'; fi
  assert_contains "$out" 'account: unknown' 'partial applicable evidence stays unknown'
  jq '.providers[].windows[].percentRemaining=0' "$SNAPSHOT" > "$TMP_ROOT/exhausted.json"
  mv "$TMP_ROOT/exhausted.json" "$SNAPSHOT"
  if out=$(select_account projects/guidex_app fable); then fail 'exhausted partial evidence selected an account'; fi
  assert_contains "$out" 'account: unavailable' 'known exhaustion outranks partial evidence'
done
fixture 60 50
jq '.providers[].quotaSemantics.effectiveAvailability |= map(select(.scope != "all_models"))' "$SNAPSHOT" > "$TMP_ROOT/missing.json"
mv "$TMP_ROOT/missing.json" "$SNAPSHOT"
if out=$(select_account projects/guidex_app fable); then fail 'missing account bound selected an account'; fi
assert_contains "$out" 'account: unknown' 'missing account bound stays unknown'
fixture 60 50
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/custom" bash "$TOOL" --snapshot "$SNAPSHOT" --project projects/guidex_app --model fable --dry-run)
assert_contains "$out" 'account: explicit' 'explicit root wins'
assert_contains "$out" "$TMP_ROOT/custom" 'explicit root is preserved'
# shellcheck disable=SC2088 # Literal tilde is deliberately supplied by a caller.
for selector in '~/.claude_b' "$HOME/.claude_b/" './relative-profile/' "$TMP_ROOT/custom"; do
  out=$(CLAUDE_CONFIG_DIR="$selector" bash "$TOOL" --snapshot "$SNAPSHOT" --project projects/guidex_app --model sonnet --dry-run)
  [ "$out" = "$(printf 'account: explicit\nconfig_dir: %s' "$selector")" ] || fail 'explicit selector spelling changed'
done
mkdir -p "$HOME/workspace/guidex-other"
expect_account 'GuideX path boundary' "$HOME/workspace/guidex-other" sonnet claude-home

fixture 20 70 39 10
out=$(CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$SNAPSHOT" --project "$HOME/workspace/other" --candidate claude:claude-fable-5-1)
[ "$out" = 'claude claude-fable-5-1' ] || fail 'ordered helper did not use GuideX Fable allowance'
fixture 0 0
jq '.providers += [{provider:"codex",accountKey:"codex-home",quotaSemantics:{status:"known",effectiveAvailability:[
  {scope:"all_models",status:"known",effectivePercentRemaining:90,runway:{status:"through_reset"}}]}}]' "$SNAPSHOT" > "$TMP_ROOT/fallback.json"
out=$(CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$TMP_ROOT/fallback.json" --project projects/guidex_app --candidate claude:fable --candidate codex:fallback)
[ "$out" = 'codex fallback' ] || fail 'ordered helper did not fall through when both accounts were exhausted'
fixture 60 50

mkdir -p "$FM_HOME/config" "$HOME/custom-profile"
fixture 70 80 30 70
printf 'ordinary\n' > "$FM_HOME/config/claude-account"
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude_b" bash "$TOOL" --snapshot "$SNAPSHOT" --project projects/guidex_app --model sonnet --dry-run)
assert_contains "$out" 'account: claude-home' 'preview must honor the ordinary pin before the inherited selector'
assert_contains "$out" 'config_dir: unset (personal)' 'ordinary preview must unset the selector'
if out=$(CLAUDE_CONFIG_DIR="$HOME/.claude_b" bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$SNAPSHOT" --project projects/guidex_app --candidate claude:fable); then fail 'ordinary pin borrowed GuideX quota'; fi
[ "$out" = none ] || fail 'ordinary pin did not enforce personal floor'
jq '.schemaVersion=5 | .providers=[(.providers[0] | del(.accountKey))]' "$SNAPSHOT" > "$TMP_ROOT/legacy-personal.json"
if out=$(CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$TMP_ROOT/legacy-personal.json" --project projects/guidex_app --candidate claude:fable); then fail 'legacy personal quota bypassed the reserve floor'; fi
[ "$out" = none ] || fail 'legacy personal floor must reject the account'
fixture 70 80 40 0
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude_b" bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$SNAPSHOT" --project projects/guidex_app --candidate claude:fable)
[ "$out" = 'claude fable' ] || fail 'ordinary pin did not override inherited GuideX selector'
printf '%s\n' "$HOME/.claude_b" > "$FM_HOME/config/claude-account"
out=$(CLAUDE_CONFIG_DIR="$HOME/custom-profile" bash "$TOOL" --snapshot "$SNAPSHOT" --project "$HOME/workspace/other" --model sonnet --dry-run)
assert_contains "$out" 'account: claude-guidex' 'preview must honor the GuideX pin'
fixture 90 20 80 10
out=$(CLAUDE_CONFIG_DIR="$HOME/custom-profile" bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$SNAPSHOT" --project "$HOME/workspace/other" --candidate claude:fable)
[ "$out" = 'claude fable' ] || fail 'GuideX pin applied personal floor'
printf '%s\n' "$HOME/custom-profile" > "$FM_HOME/config/claude-account"
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude_b" bash "$TOOL" --snapshot "$SNAPSHOT" --project projects/guidex_app --model fable --dry-run)
assert_contains "$out" 'account: claude-explicit' 'preview must retain an unmeasured custom pin'
assert_contains "$out" "config_dir: $HOME/custom-profile" 'preview must report the pinned root'
for schema in 5 6; do
  if [ "$schema" = 5 ]; then
    jq '.schemaVersion=5 | .providers=[(.providers[0] | del(.accountKey))]' "$SNAPSHOT" > "$TMP_ROOT/pin-quota.json"
  else
    jq '.providers += [(.providers[0] | .accountKey="default")]' "$SNAPSHOT" > "$TMP_ROOT/pin-quota.json"
  fi
  if out=$(CLAUDE_CONFIG_DIR="$HOME/.claude_b" bash "$ROOT/bin/fm-quota-choose.sh" --snapshot "$TMP_ROOT/pin-quota.json" --project projects/guidex_app --candidate claude:fable); then fail 'custom pin borrowed provider fallback quota'; fi
  [ "$out" = none ] || fail 'custom pin must stay unmeasured'
done
rm "$FM_HOME/config/claude-account"
fixture 60 50

# The account collector delegates all credential access to quota-axi. A double
# checks that the personal login is selected by an unset variable, not ~/.claude.
cat > "$TMP_ROOT/tools/quota-axi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s\n' "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "$*" >> "$QUOTA_CALLS"
if [ "${CLAUDE_CONFIG_DIR-unset}" = unset ]; then
  jq '.schemaVersion=5 | .providers=[(.providers[0] | del(.accountKey))]' "$QUOTA_FIXTURE"
else
  [ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude_b" ] || exit 2
  jq '.schemaVersion=5 | .providers=[(.providers[1] | del(.accountKey))]' "$QUOTA_FIXTURE"
fi
SH
chmod +x "$TMP_ROOT/tools/quota-axi"
export PATH="$TMP_ROOT/tools:$PATH" QUOTA_CALLS="$TMP_ROOT/calls" QUOTA_FIXTURE="$SNAPSHOT"
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/inherited" CLAUDE_CODE_OAUTH_TOKEN=fixture bash "$TOOL" --json)
jq -e '.schemaVersion==6 and ([.providers[].accountKey]|sort)==["claude-guidex","claude-home"]' <<< "$out" >/dev/null || fail 'collector did not expand both Claude rows'
grep -q '^unset|unset|--json --no-credential-refresh$' "$QUOTA_CALLS" || fail 'personal collection changed its Keychain selector or kept an ambient token'
grep -qF "$HOME/.claude_b|unset|--provider claude --json --no-credential-refresh" "$QUOTA_CALLS" || fail 'GuideX collection selected the wrong login'
out=$(bash "$TOOL" --snapshot "$SNAPSHOT")
assert_contains "$out" 'claude-home' 'report labels personal account'
assert_contains "$out" 'claude-guidex' 'report labels GuideX account'
assert_contains "$out" 'Fable weekly remaining=60%' 'report includes personal weekly allowance'
assert_contains "$out" 'Fable weekly remaining=50%' 'report includes GuideX weekly allowance'

# Public spawn helper: an injected executable proves the probe's argv and
# environment without looking at credential files or spending model tokens.
. "$ROOT/bin/fm-claude-accounts-lib.sh"
cat > "$TMP_ROOT/tools/claude-status" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${USER-missing}" "\${LOGNAME-missing}" "\$*" >> '$TMP_ROOT/auth-calls'
[ ! -e '$TMP_ROOT/signed-out' ]
SH
chmod +x "$TMP_ROOT/tools/claude-status"
selected_root=$(USER=fixture-user LOGNAME=fixture-user CLAUDE_CONFIG_DIR='' fm_claude_spawn_root projects/guidex_app "$TMP_ROOT/projects" sonnet "$TMP_ROOT/tools/claude-status")
[ "$selected_root" = "$HOME/.claude_b" ] || fail 'spawn helper selected a different root'
grep -qxF "$selected_root|fixture-user|fixture-user|auth status" "$TMP_ROOT/auth-calls" || fail 'status probe lost selector, USER, LOGNAME, or status-only argv'
touch "$TMP_ROOT/signed-out"
if CLAUDE_CONFIG_DIR='' fm_claude_spawn_root projects/guidex_app "$TMP_ROOT/projects" sonnet "$TMP_ROOT/tools/claude-status" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then fail 'signed-out GuideX account accepted'; fi
assert_contains "$(cat "$TMP_ROOT/err")" 'not signed in' 'sign-out diagnostic'
rm "$TMP_ROOT/signed-out"
fixture 80 30
selected_root=$(CLAUDE_CONFIG_DIR='' fm_claude_spawn_root projects/guidex_app "$TMP_ROOT/projects" claude-fable-5-1 "$TMP_ROOT/tools/claude-status")
[ -z "$selected_root" ] || fail 'Fable spawn did not use the larger personal weekly allowance'
grep -q '^unset|.*|auth status$' "$TMP_ROOT/auth-calls" || fail 'personal Fable probe set CLAUDE_CONFIG_DIR'
fixture 20 80
selected_root=$(CLAUDE_CONFIG_DIR='' fm_claude_spawn_root "$HOME/workspace/other" "$TMP_ROOT/projects" fable "$TMP_ROOT/tools/claude-status")
[ "$selected_root" = "$HOME/.claude_b" ] || fail 'Fable spawn did not use the larger GuideX weekly allowance'
fixture 0 0
if CLAUDE_CONFIG_DIR='' fm_claude_spawn_root projects/guidex_app "$TMP_ROOT/projects" fable "$TMP_ROOT/tools/claude-status" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then fail 'spawn selected an exhausted Fable account'; fi
assert_contains "$(cat "$TMP_ROOT/err")" 'remaining dispatch profiles' 'spawn requests fallback instead of launching exhausted Fable'
ln -s "$HOME/.claude_b" "$TMP_ROOT/profile-link"
selected_root=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/profile-link/" fm_claude_spawn_root projects/guidex_app "$TMP_ROOT/projects" sonnet "$TMP_ROOT/tools/claude-status")
[ "$selected_root" = "$TMP_ROOT/profile-link/" ] || fail 'normalization rewrote a symlink selector'
pass 'Claude account routing, personal floor, unknown evidence, and per-account reporting'
