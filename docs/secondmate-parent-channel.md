# Secondmate parent channel

This note records why a secondmate home's captain-facing outcomes are delivered by scripts instead of by the mate model, and which script delivers each one.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The problem

A secondmate is a firstmate in its own home, and nobody reads its chat: the captain and the main firstmate see only what is appended to the parent channel.
On 2026-09-02 four outcomes across two mate homes never reached the captain.
The watcher had delivered the parent's request within a minute each time, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: the mate can satisfy the [address rule in `AGENTS.md`](../AGENTS.md#firstmate) in local chat while missing the charter's later return-channel instruction.
The captain's framing of the requirement was: "the root problem is not specific to PRs, right? it looks like any message or outcomes from second mates can miss. we need to make sure our fixes are addressing this in a principled, fundamental way, not surgically treating the symptoms of just this PR update miss."
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## The design

The delivery rule has one sentence: the scripts report facts, the mate reports judgement.
Every captain-facing outcome that leaves durable evidence in the mate home is published on the channel by the script that records that evidence, at record time or on the next supervision poll, and the charter reserves the mate's own appends for judgement.

| Outcome | Durable evidence in the mate home | Published by |
|---|---|---|
| Ship child PR ready | the child's `done:` PR ready line, whose accepted spellings the publisher below owns; `pr=` in the child's record once registered | `bin/fm-inactive-reconcile.sh` on the next poll with the child's line; `bin/fm-pr-check.sh` at registration with the canonical URL |
| Scout child findings | the child's `done:` line plus `data/<child>/report.md` | `bin/fm-inactive-reconcile.sh` on the next poll, with the report pointer |
| Child failed | the child's `failed:` line | `bin/fm-inactive-reconcile.sh` on the next poll |
| Child decision escalated to the captain | the task held for the captain in the mate backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` |
| PR merged | the merge poll or the mate's own merge | `bin/fm-merge-outcome-lib.sh` |
| Child leaving the home | its final ledger line | `bin/fm-teardown.sh`, which refuses to remove the child while that line is undelivered |
| Child ended silently | terminal current state with a silent ledger | the existing inactive-outcome scan in `bin/fm-inactive-reconcile.sh` |
| Answer to a marked request | a correlated line guarded by the pending-reply record | `bin/fm-secondmate-report.sh`, which resolves the parent channel from the mate home; the pending-reply guard repairs a line stranded in the local mate's same-basename status file before recovery or escalation |
| Session lock refusal | a keyed blocker on the parent channel | `bin/fm-session-start.sh` through `bin/fm-parent-channel-lib.sh` |
| An outcome that exists only in the mate's reasoning | none | the charter and the `AGENTS.md` carve-outs only |

The ledger delivery reads files, plus a local git reachability check on a ship `done:` with no delivery record yet (`bin/fm-dod-lib.sh`): it calls no harness, no forge, and no current-state reader, so it is identical for every harness and runtime backend.
Each delivery is keyed with the first eight hexadecimal characters of its receipt fingerprint and uses the shared append contract above, and the ledger path reuses the inactive scan's per-fingerprint receipts, so a replayed poll or restart cannot deliver an event twice while a genuinely new terminal event is delivered again.
A duplicate line is harmless and a missed one is not, so the mate may still append its own judgement about a delivered outcome, and the parent reads the script's line as the fact and the mate's line as commentary.
For marked replies, the report helper accepts no caller-selected destination and uses the channel resolver for both local and remote homes; its script header owns the exact invocation contract.
The pending-reply guard may restate only the correlated line from a local mate's `state/<mate-id>.status` onto the parent channel, which repairs the common parent-home versus mate-home mixup without accepting arbitrary mate-home sightings as acknowledgement.
Other correlated mate-home status lines remain wrong-home evidence, while a remote home's routed `state/parent-replies.status` is already the parent channel and is not classified as wrong-home.
The mate home's own status scans treat that remote channel the same way: `status_scan_parent_channel_exclude` in `bin/fm-classify-lib.sh` resolves the outbound path through the same `bin/fm-parent-channel-lib.sh` binding, and the watcher's signal scan and heartbeat backstop, the away-mode daemon's catch-all scan, and the fleet-wide folds skip exactly that resolved path, never a file name.
The remote reply adapter already mirrors every channel line into the parent home, so folding the channel again here would only spin spurious wakes and a phantom `parent-replies` task, while a `parent-replies.status` in a main home or in a local mate is an ordinary task log that keeps folding and waking.
A missed-reply escalation includes the complete first sighting path and line number in readable shell-escaped form.

## Lock refusal and unanswered requests

A lock-refused secondmate reports `blocked [key=secondmate-readonly]` through its bound parent channel.
The publisher uses the optional open-decision key on `fm_parent_channel_report` to suppress retries while that decision remains open.
When session start verifies restored lock ownership, it closes the episode on the same source channel.
For a remote mate, this writes the resolution to its own `parent-replies.status`, which the parent mirror then carries upstream.
A parent-local decision close alone does not update that remote source log.
A later refusal opens a new episode, even when the report text is identical; repeated healthy starts publish no extra resolution.
Other publishers retain their existing event deduplication.
A main home publishes nothing upward.

The parent pending-reply guard retains the completed-turn recovery and escalation grace.
When no completion has been observed, a delivered request or delivered recovery escalates after one hour without a correlated reply.
Each wait uses its own delivery timestamp.
A remote escalation requires the reply-channel mirror watermark to cover that wait's one-hour deadline.
The guard rechecks for a correlated reply before publishing and closes its keyed escalation when a reply arrives.
This is a parent-owned escalation path: it runs independently of the mate's watcher and can escalate an unanswered steer during a gap in the mate's supervision.

### Cause of the recurring supervision gaps

The read-only investigation of agent-station established that its Codex home had the supervision host disabled.
Each bounded 180-second checkpoint ran a one-shot watcher, which ended normally rather than crashing.
Watcher liveness therefore depended on the model issuing the next checkpoint.
During long work outside a checkpoint, no watcher polled the fleet, while queued steering messages remained unread until the model returned to handling them.
The remote triage-log gaps and watcher-down markers confirmed those blind intervals.
The parent-owned escalation above addresses the unacknowledged steering requests without depending on that missing mate-side polling.

The recommended operational follow-up is to enable `config/supervision-host` for Codex secondmates, using the [supported engine and opt-out rules](configuration.md#supervision-host-configsupervision-host).
The host manages successor watcher cycles during wake handling, so that re-arm no longer waits for the model's next checkpoint.
The host's [Codex park boundary](supervision-host.md#codex-checkpoint-bound) still applies.
This recommendation requires the captain's decision; this change does not enable the host or alter any home's configuration.
Codex's inability to reason during a foreground tool call remains an upstream checkpoint-design constraint, outside this change.

## What is deliberately not built

- No mirror of the mate's chat: chat can mix outcomes with other conversation, so choosing which sentence is an outcome would itself be model behavior, and every harness exposes turn text differently.
- No threshold escalation of a child's open decision or blocker: a decision the mate escalates is a captain hold, which is published; a decision the mate neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No second watcher or standalone scanner: a lightweight ledger pass runs inside the existing inactive-outcome command on every watcher poll and reuses its receipts and upstream append.
- No orphan lifecycle: teardown refuses instead of removing an undelivered outcome, the same way it refuses on other unlanded conditions.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers the ledger delivery against real ledgers with no harness: immediate done and failed delivery with note, PR, mode, posture, and report pointer, once-only delivery across polls, a ship `done:` withheld while its named head exists only in the worker copy, a pending one still delivered after teardown removes that copy, a line still being appended, later routine status prose not minting a fresh parent event because the inactive receipt identity binds structured fields only, the remote route, the yield of the inactive path to a terminal ledger, and the real watcher poll driving it.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers teardown delivering a child's final line and refusing when the channel cannot be written.
`tests/fm-brief.test.sh` pins the charter's channel rule.
`tests/fm-session-start.test.sh` covers local and remote lock-refusal episodes, repeat suppression, source closure on verified recovery, reopening across repeated recovery cycles, and main-home silence.
`tests/fm-pending-reply.test.sh` covers request and recovery backstops, completion grace, deadline-based mirror evidence, late-reply closure, and helper-selected local routing, remote-channel classification, same-basename restatement before false escalation, readable wrong-home diagnostics, and the rule that arbitrary mate-home sightings never acknowledge a reply.
`tests/fm-parent-channel-scan-exclusion.test.sh` covers the home-shape-aware scan exclusion against real remote, main-home, and local-mate fixtures: the watcher signal scan, both heartbeat backstops, the fleet-wide folds, and the real `fm-wake-drain.sh` end to end.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: real tmux panes, both real watchers re-armed after each wake, and no model, with every delivered parent line and the parent wake it produced.
