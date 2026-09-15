#!/usr/bin/env bash
# Drive bin/fm-remote-home-seed.sh from a parent home whose path contains glob
# metacharacters ("fm[1]"), across the same fake-SSH boundary the lifecycle e2e
# test uses (the fake ssh execs the real fm-remote-entrypoint.sh locally), then
# print the steering/status lines of the charter the remote home received.
# Usage: seed-charter-drive.sh <label> <parent-side-code-root> <remote-code-root> <fake-ssh-source-test>
set -u
LABEL=$1 PROOT=$2 RROOT=$3 E2E=$4
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nm-seed-$LABEL.XXXXXX"); TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/fm[1]"; REMOTE_ROOT="$TMP_ROOT/remote-root"; REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN="$TMP_ROOT/fake"; CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS" "$FAKEBIN"
cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$PROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; sleep 0.3; fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
( cd "$RROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - . ) | ( cd "$REMOTE_ROOT" && tar -xf - )
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" -c user.email=t@e.com -c user.name=T add .
git -C "$REMOTE_ROOT" -c user.email=t@e.com -c user.name=T commit -qm "Remote fixture root"
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" -c user.email=t@e.com -c user.name=T add README.md
git -C "$PARENT/projects/alpha" -c user.email=t@e.com -c user.name=T commit -qm "Initial alpha"
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-02)\n' > "$PARENT/data/projects.md"
printf 'codex\n' > "$PARENT/config/secondmate-harness"; printf 'tmux\n' > "$PARENT/config/backend"
# The fake ssh transport, verbatim from the lifecycle e2e test.
sed -n "/^cat > \"\$FAKEBIN\/fake-ssh\" <<'SH'$/,/^SH$/p" "$E2E" | sed '1d;$d' > "$FAKEBIN/fake-ssh"; chmod +x "$FAKEBIN/fake-ssh"
echo "### $LABEL: parent-side seed script = $PROOT/bin/fm-remote-home-seed.sh"
echo "    parent FM_HOME = $PARENT"
echo "\$ FM_HOME=\"\$PARENT\" fm-remote-home-seed.sh ios remote-mac \"\$REMOTE_ROOT\" \"\$REMOTE_HOME\" alpha"
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_COUNT="$TMP_ROOT/ssh.count" \
FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
FM_FAKE_SSH_MODE=normal FM_FAKE_REMOTE_CWD="$TMP_ROOT" FM_FAKE_DOCTOR_LOG="$TMP_ROOT/doctor.log" \
FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  "$PROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha; echo "(exit $?)"
echo "-- ssh calls: $(cat "$TMP_ROOT/ssh.count" 2>/dev/null)"
echo "-- parent charter (data/ios/brief.md) route lines:"; grep -n "ios.status\|ios.inbox" "$PARENT/data/ios/brief.md" | sed 's/^/   /'
echo "-- remote charter received on the remote host ($REMOTE_HOME/data/charter.md) route lines:"
grep -n "\.status\|\.inbox" "$REMOTE_HOME/data/charter.md" 2>/dev/null | sed 's/^/   /' || echo "   (no remote charter)"
echo "-- verdict:"
if grep -Fq "$PARENT/state/ios.inbox" "$REMOTE_HOME/data/charter.md" 2>/dev/null; then echo "   FAIL: remote charter still names the parent's inaccessible inbox"; else echo "   ok: parent inbox path absent from remote charter"; fi
if grep -Fq "$PARENT/state/ios.status" "$REMOTE_HOME/data/charter.md" 2>/dev/null; then echo "   FAIL: remote charter still names the parent's inaccessible status path"; else echo "   ok: parent status path absent from remote charter"; fi
if grep -Fq "'$REMOTE_HOME/state/parent-route/ios.inbox'" "$REMOTE_HOME/data/charter.md" 2>/dev/null; then echo "   ok: remote charter names the host-local inbox $REMOTE_HOME/state/parent-route/ios.inbox"; else echo "   FAIL: remote charter does not name the host-local inbox cleanly"; fi
if grep -Fq "'$REMOTE_HOME/state/parent-replies.status'" "$REMOTE_HOME/data/charter.md" 2>/dev/null; then echo "   ok: remote charter names the host-local reply log $REMOTE_HOME/state/parent-replies.status"; else echo "   FAIL: remote charter does not name the host-local reply log cleanly"; fi
