#!/usr/bin/env bash
# tests/fm-secondmate-availability.test.sh - availability-aware routing for
# remote second mates whose host is not always on.
#
# The guarantees under test:
#   - data/secondmates.md accepts one optional `availability: when-online`
#     field on a remote route and rejects any other value or a local route
#     carrying it, so a typo can never silently select a routing posture.
#   - bin/fm-secondmate-availability.sh answers an always-on route with
#     `route` and never probes it, so existing second mates are unchanged.
#   - A when-online route is probed once, read-only and within its time
#     budget, through the same remote state call the watcher's liveness tick
#     uses; only `alive` routes there.
#   - Any other outcome falls back: portable work runs locally and host-bound
#     work stays queued, each with the probe's reason.
#   - The fleet snapshot still reads an opted-in route as a remote route.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-availability)
AVAIL="$ROOT/bin/fm-secondmate-availability.sh"

# make_world <name> <registry-suffix-before-scope>: a parent home with one
# remote second mate `lap` on host lab-host, a recorded remote endpoint, and
# a fake ssh that logs each call and answers FM_FAKE_REMOTE_REPLY on
# FM_FAKE_REMOTE_RC after FM_FAKE_REMOTE_DELAY seconds.
make_world() {
  local name=$1 extra=$2 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  fm_write_meta "$w/home/state/lap.meta" \
    "window=remote:lap" "kind=secondmate" "harness=claude" \
    "remote_host=lab-host" "remote_backend=herdr" "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1" "home=/remote/lap-home"
  printf -- '- lap - Laptop hands (host: lab-host; root: /remote/root; home: /remote/lap-home; %sscope: laptop-only work; projects: alpha; added 2026-10-12)\n' \
    "$extra" > "$w/home/data/secondmates.md"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
sleep "${FM_FAKE_REMOTE_DELAY:-0}"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  : > "$w/ssh.log"
  printf '%s\n' "$w"
}

# avail <w> [env...] -- <args...>: run the command against world <w>; prints
# "<rc>|<stdout>" so callers assert the decision and exit status together.
avail() {
  local w=$1 envs=() out rc
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out=$(env FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" FM_STATE_OVERRIDE="$w/home/state" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" ${envs[@]+"${envs[@]}"} "$AVAIL" "$@" 2>&1) && rc=0 || rc=$?
  printf '%s|%s\n' "$rc" "$out"
}

calls() { wc -l < "$1/ssh.log" | tr -d ' '; }

test_registry_field() {
  local w reg out
  w=$(make_world registry 'availability: when-online; ')
  reg="$w/home/data/secondmates.md"
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  out=$(bash -c '. "$0/bin/fm-secondmate-registry-lib.sh"
    for f in availability host home scope projects remote; do
      printf "%s=%s\n" "$f" "$(secondmate_registry_field "$1" lap "$f")"
    done
    secondmate_registry_validate_bindings "$1" secondmate_registry_path_key lap && echo valid' "$ROOT" "$reg")
  [ "$out" = "availability=when-online
host=lab-host
home=/remote/lap-home
scope=laptop-only work
projects=alpha
remote=1
valid" ] || fail "an opted-in remote route should parse every field, got: $out"

  printf -- '- box - Always on (host: box; root: /r/root; home: /r/home; scope: box work; projects: alpha; added 2026-10-12)\n' > "$reg"
  # shellcheck disable=SC2016
  out=$(bash -c '. "$0/bin/fm-secondmate-registry-lib.sh"; secondmate_registry_field "$1" box availability' "$ROOT" "$reg")
  [ "$out" = "" ] || fail "a route without the field should read as always-on, got: $out"

  for bad in \
    '- box - Typo (host: box; root: /r/root; home: /r/home; availability: when-onlin; scope: box work; projects: alpha; added 2026-10-12)' \
    '- box - Empty (host: box; root: /r/root; home: /r/home; availability: ; scope: box work; projects: alpha; added 2026-10-12)' \
    '- box - Local (home: /r/home; availability: when-online; scope: box work; projects: alpha; added 2026-10-12)'; do
    printf '%s\n' "$bad" > "$reg"
    # shellcheck disable=SC2016
    if bash -c '. "$0/bin/fm-secondmate-registry-lib.sh"; secondmate_registry_line_for_id "$1" box' "$ROOT" "$reg"; then
      fail "a malformed availability entry must not parse: $bad"
    fi
  done
  pass "registry: when-online is the only availability value, and only on a remote route"
}

test_always_on_route_is_not_probed() {
  local w out
  w=$(make_world always-on '')
  out=$(avail "$w" FM_FAKE_REMOTE_RC=255 -- lap)
  [ "$out" = '0|route lap: always-on route; no availability probe needed' ] \
    || fail "an always-on route must route without a probe, got: $out"
  out=$(avail "$w" FM_FAKE_REMOTE_RC=255 -- lap host-bound)
  assert_contains "$out" '0|route lap:' "host-bound work must still route to an always-on mate"
  [ "$(calls "$w")" -eq 0 ] || fail "an always-on route was probed: $(cat "$w/ssh.log")"
  pass "always-on: existing routes decide without any remote call"
}

test_when_online_alive_routes() {
  local w out
  w=$(make_world alive 'availability: when-online; ')
  out=$(avail "$w" FM_FAKE_REMOTE_REPLY=alive -- lap)
  [ "$out" = '0|route lap: host lab-host reachable and second mate live' ] \
    || fail "a live when-online mate should take the work, got: $out"
  [ "$(calls "$w")" -eq 1 ] || fail "the probe should spend exactly one remote call: $(cat "$w/ssh.log")"
  assert_contains "$(cat "$w/ssh.log")" 'lab-host' "the probe should reach the registered host"
  pass "when-online: a reachable, live mate routes after one remote state call"
}

test_when_online_unavailable_falls_back() {
  local w out
  w=$(make_world asleep 'availability: when-online; ')
  cp "$w/home/state/lap.meta" "$w/meta.before"
  cp "$w/home/data/secondmates.md" "$w/registry.before"

  out=$(avail "$w" FM_FAKE_REMOTE_RC=255 -- lap)
  [ "$out" = '1|local lap: remote host unavailable or endpoint state unknown; route preserved on lab-host; run portable work in this home' ] \
    || fail "an unreachable host should send portable work local, got: $out"
  out=$(avail "$w" FM_FAKE_REMOTE_RC=255 -- lap host-bound)
  [ "$out" = '1|queue lap: remote host unavailable or endpoint state unknown; route preserved on lab-host; keep host-bound work queued until lab-host is reachable' ] \
    || fail "an unreachable host should keep host-bound work queued, got: $out"

  out=$(avail "$w" FM_FAKE_REMOTE_REPLY=dead -- lap)
  [ "$out" = '1|local lap: host lab-host reachable but the second mate endpoint is dead until liveness recovery relaunches it; run portable work in this home' ] \
    || fail "a reachable host with no running mate should not take work, got: $out"
  out=$(avail "$w" FM_FAKE_REMOTE_REPLY=ambiguous -- lap host-bound)
  assert_contains "$out" '1|queue lap: remote endpoint state is ambiguous on lab-host;' \
    "an inconclusive state should keep host-bound work queued"

  cmp -s "$w/meta.before" "$w/home/state/lap.meta" || fail "the probe changed endpoint metadata"
  cmp -s "$w/registry.before" "$w/home/data/secondmates.md" || fail "the probe changed the registry"
  pass "when-online: unreachable or not-running mates fall back without changing any record"
}

test_when_online_probe_is_bounded() {
  local w out started elapsed
  w=$(make_world slow 'availability: when-online; ')
  started=$(date +%s)
  out=$(avail "$w" FM_SECONDMATE_LIVENESS_PROBE_TIMEOUT=1 FM_FAKE_REMOTE_REPLY=alive FM_FAKE_REMOTE_DELAY=8 -- lap)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] || fail "the availability probe exceeded its 1s budget (${elapsed}s)"
  [ "$out" = '1|local lap: remote endpoint state probe timed out after 1s; route preserved on lab-host; run portable work in this home' ] \
    || fail "a timed-out probe must not route on partial output, got: $out"
  pass "when-online: a hung host is bounded by the probe budget and never routes"
}

test_when_online_without_endpoint() {
  local w out
  w=$(make_world unlaunched 'availability: when-online; ')
  rm -f "$w/home/state/lap.meta"
  out=$(avail "$w" -- lap)
  [ "$out" = '1|local lap: no running remote endpoint is recorded for lap; run portable work in this home' ] \
    || fail "a never-launched mate should not take work, got: $out"
  [ "$(calls "$w")" -eq 0 ] || fail "a mate with no recorded endpoint was probed"
  pass "when-online: a mate with no recorded endpoint falls back without a remote call"
}

test_usage_and_registry_errors() {
  local w out
  w=$(make_world errors 'availability: when-online; ')
  out=$(avail "$w" -- nobody)
  assert_contains "$out" '2|error: no single well-formed registry entry for secondmate nobody' \
    "an unregistered id must be an error"
  out=$(avail "$w" -- lap sometimes)
  case "$out" in 2\|*) ;; *) fail "an unknown work kind must be a usage error, got: $out" ;; esac
  out=$(avail "$w" -- '../lap')
  assert_contains "$out" '2|error: invalid secondmate id' "an unsafe id must be refused"
  printf -- '- lap - Typo (host: lab-host; root: /remote/root; home: /remote/lap-home; availability: online; scope: x; projects: alpha; added 2026-10-12)\n' \
    > "$w/home/data/secondmates.md"
  out=$(avail "$w" FM_FAKE_REMOTE_REPLY=alive -- lap)
  assert_contains "$out" '2|error:' "a malformed availability value must not decide a route"
  [ "$(calls "$w")" -eq 0 ] || fail "an error path made a remote call"
  pass "errors: unknown ids, unsafe ids, bad work kinds, and malformed entries exit 2 without probing"
}

test_seed_refuses_unknown_availability() {
  local w out rc
  w="$TMP_ROOT/seed"
  mkdir -p "$w/data" "$w/state"
  out=$(FM_HOME="$w" FM_DATA_OVERRIDE="$w/data" FM_STATE_OVERRIDE="$w/state" \
    FM_SECONDMATE_AVAILABILITY=sometimes \
    "$ROOT/bin/fm-remote-home-seed.sh" lap lab-host /remote/root /remote/lap-home --no-projects 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "the seed accepted an unknown availability value"
  assert_contains "$out" 'FM_SECONDMATE_AVAILABILITY must be when-online or unset' \
    "the seed should name the accepted availability value"
  [ ! -e "$w/data/secondmates.md" ] || fail "a refused seed wrote the registry"
  pass "seed: an unknown availability value is refused before the registry is touched"
}

test_fleet_snapshot_reads_opted_in_route() {
  local w out
  w=$(make_world snapshot 'availability: when-online; ')
  : > "$w/home/data/backlog.md"
  mkdir -p "$w/home/projects"
  out=$(FM_HOME="$w/home" FM_SSH_BIN=/usr/bin/false FM_SNAPSHOT_BUDGET=1 \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null \
    | jq -c '[.. | objects | select(.id? == "lap" and has("registry_error")) | {host,remote,registry_error}] | first')
  [ "$out" = '{"host":"lab-host","remote":true,"registry_error":null}' ] \
    || fail "the fleet snapshot should read an opted-in route as remote, got: $out"
  pass "fleet snapshot: an opted-in route stays a well-formed remote route"
}

test_registry_field
test_always_on_route_is_not_probed
test_when_online_alive_routes
test_when_online_unavailable_falls_back
test_when_online_probe_is_bounded
test_when_online_without_endpoint
test_usage_and_registry_errors
test_seed_refuses_unknown_availability
test_fleet_snapshot_reads_opted_in_route

echo "# all fm-secondmate-availability tests passed"
