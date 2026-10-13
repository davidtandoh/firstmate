# Omnigent launch boundary

```mermaid
flowchart LR
    spawn[fm-spawn: native profile] --> launcher[fm-omnigent: admission]
    selector[Kit runtime selector] --> launcher
    receipt[Omnigent launch receipt] --> launcher
    policy[Kit telemetry policy] --> launcher
    launcher --> worker[Native harness with Firstmate hooks]
```

Firstmate admits a native launch from verified runtime and policy evidence; trace availability is a separate result.
[Configuration](configuration.md#omnigent-launch-mode-configomnigent--fm_omnigent) owns enablement, setup, and supported limits.

`bin/fm-spawn.sh` resolves mode before endpoint creation and preserves the dispatched harness, model, and effort.
The launch template substitutes the Omnigent boundary for the native executable.
Native permission flags, prompts, busy hooks, and turn-end wiring retain their existing owners.
Quota dispatch continues to use the native harness identity.

`bin/fm-omnigent.sh` queries the Kit runtime selector and telemetry policy for every preflight and again when the pane executes its launch.
The selector supplies the executable, full measured runtime identity, loopback endpoint, and exact client environment.
The launcher does not infer an executable from a state directory or use a separate Omnigent executable on `PATH`.
The selected executable must return a public launch receipt that matches the entire selected runtime identity and client environment.
The launcher verifies callable harness capabilities and the existing native `--env` interface.
The public receipt retains endpoint, authentication, runtime-generation, and environment refusals.
A failure never executes the original native command as a fallback.

The Kit owns telemetry policy, content capture, redaction, delivery, retry, and loss reporting.
Permitted admission continues during a trace gap and emits a separate degradation diagnostic.
Required collection denies new admission when collection is unavailable.
Excluded capture disables telemetry and removes export destinations from the attaching client and explicit native settings.
Enabled export uses only the policy's loopback redactor destination.
Unknown loss counters remain unknown; memory-only retry does not prove durable acceptance.
Telemetry checks have no authority to stop or replace an existing session.

The service starts native terminals in a different process tree.
Shell inheritance into the CLI alone does not reach those terminals.
The launcher therefore sends the Firstmate-owned environment through Omnigent's explicit native `--env` interface, including `FM_BACKEND`, secondmate home isolation, and the inherited session mode.
It clears foreign harness markers and absent Firstmate routing variables, and leaves Omnigent's managed Codex home intact.
The launcher does not copy arbitrary ambient credentials.

Remote launch and recovery retain the existing SSH control boundary.
The parent sends its resolved mode for launch and relaunch, including secondmate restarts, and the destination resolves its own Kit service.
The remote endpoint reports its actual mode to the parent, alongside its native profile.
A recorded wrapped task remains wrapped through recovery.

## Scoped recovery

1. Leave a running session and its durable inbox intact when telemetry reports a gap.
   Diagnose the collector or trace store through the Kit's component owner.
2. Before a new launch, run the read-only launcher `check` with the intended worker configuration and harness.
   The launcher's [help](../bin/fm-omnigent.sh) owns exact flags; its [receipt validator](../bin/fm-omnigent-contract.jq) owns consumer validation and safe refusal categories.
3. If runtime, endpoint, authentication, capability, or policy verification refuses, repair that owner before retrying admission.
   Do not substitute a binary on `PATH`, remove an account pin, or use a direct exporter as a workaround.
4. For a task with a public Codex binding, use [`fm-control reattach`](agent-control.md#native-session-reattachment) after the attachment has exited and its recorded endpoint is agent-free.
   The command verifies the binding before sending one attachment command.
   An occupied, missing, unreadable, or foreign endpoint refuses.
5. Use [`fm-control relaunch`](agent-control.md#transactional-relaunch) only for an explicitly requested replacement of a task without a native binding.
   Wrapped relaunch checks admission and worker restrictions before stopping the current agent.
   The launch checks again at pane execution; a later availability change can still refuse the replacement.

## Native task association

```mermaid
flowchart LR
    spawn[fm-spawn: task launch] --> binding[Public Omnigent binding]
    binding --> task[Existing task data directory]
    control[fm-control: typed reattach] --> verify[Owner validates exact binding]
    task --> verify
    verify --> attach[Attach existing native terminal once]
```

The binding associates one existing Firstmate task with an Omnigent session; Omnigent retains custody.

For a measured `durable_custody=true` Codex capability, the worker launcher requests the owner's public binding before attaching to the native terminal.
The launcher stores the exact binding as a private `omnigent-binding.json` in the task's existing data directory.
The binding identifies the session, runner, owner generation, owner and native process identities, terminal socket, workspace, endpoint, and config/environment digests.
The [binding validator](../bin/fm-omnigent-contract.jq) owns the executable schema checks.
The [association helper](../bin/fm-omnigent-binding-lib.sh) checks private-file safety and refuses duplicate session, runner, or native process associations among this home's existing tasks.
Firstmate does not enumerate Omnigent's private records or maintain another custody registry.

Before native creation, the launcher reserves the task binding path exclusively under the existing task-set lock.
A failed or interrupted creation retains that empty reservation because the consumer cannot prove that no owner was created.
If a reservation is empty, malformed, unsafe, or missing after an uncertain launch, stop and reconcile with Omnigent's owner.
Do not remove the reservation and retry creation or guess an identity from terminal output.
Existing task records without a binding remain unchanged; maintenance reattachment refuses them.

Typed reattachment uses the same selected-runtime, endpoint, authentication, environment, and callable-capability checks as launch.
The owner's public verifier must return the entire recorded binding unchanged before attachment.
Reattachment does not query new-admission telemetry policy, resend a prompt, replay launch options, or create a replacement native session.
The task metadata, brief, worktree, and durable inbox remain intact.
The control plane refuses an occupied endpoint and never submits a second attachment command as an Enter retry.
Both control-plane relaunch and direct spawn replacement refuse a bound task before changing its records or stopping its attachment.
Do not send maintenance detach or other lifecycle commands as steering text.

The binding integration follows the published Omnigent schema version 1 interface at source commit `17b6afc0e951bb370ce725abfa87d5e67dfe0a2d`.
The owner advisory identified incomplete client identity fields and teardown recovery defects at that source commit.
The owner must return the corrected identity and end contract before this consumer's impacted integration is finalized.
Firstmate must not compensate with ambient environment guesses, wider allowlists, private-state reads, or weaker identity equality.
Intentional end qualification and integrated mandatory acceptance remain pending.
The source fixtures do not prove installed compatibility, host maintenance, native process survival, or phone continuity.
Custody capability remains limited to host-launched Codex on macOS; false capability rows retain their existing launch path.
Full runner replacement, runner-crash survival, and same-process survival through OS reboot are not claimed.
See the [acceptance matrix](verification/omnigent.md#independent-launch-acceptance-matrix) for the separate destination proof.

`bin/fm-agent-process-lib.sh` recognizes the observed Python interpreter, Omnigent entrypoint, and native subcommand in order.
A Python process merely mentioning Omnigent, or running its server, is not an agent.
The native harness remains the identity used by steering, interrupt, and exit.
A live wrapper alone does not prove that a model turn completed or that MLflow received its trace.
[Verification](verification/omnigent.md) separates those claims.

## Conversation banner and draft protection

Shared composer classification and selected-content extraction remove one trailing `Omnigent: http://127.0.0.1:<port>/c/<32 lowercase hex digits>` line and any blank rows after it before reading the native composer.
The port must contain only decimal digits.
ANSI styling and trailing terminal padding do not change the match; other hosts, malformed URLs, and nonfinal banner rows remain content.
A final exact-match line is treated as wrapper output even without separate wrapper identity.
This prevents the banner from making an empty composer appear to hold a draft.
Native draft selection remains owned by [`bin/fm-composer-lib.sh`](../bin/fm-composer-lib.sh), including its enclosing-composer safety boundary.
The [conversation-footer verification record](verification/omnigent.md#2026-10-12-conversation-footer) distinguishes regression coverage from live evidence.
