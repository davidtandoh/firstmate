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
The declared client inputs `CODEX_HOME` and `OMNIGENT_CODEX_PATH` select the source Codex config/auth home and native executable.
The launcher passes only their present invoking-environment values and requires the receipt to echo them exactly.
It does not infer paths or add those selectors to the separate native `--env` settings.
Omnigent continues to own the native session's managed Codex home.
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
5. To intentionally end a bound task, use `fm-control <task-id> exit`.
   The control plane requires the owner's exact ended receipt before claiming native end.
   A refusal or timeout preserves the task records; reconcile the recorded owner scope before retrying.
6. Use [`fm-control relaunch`](agent-control.md#transactional-relaunch) only for an explicitly requested replacement of a task without a native binding.
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

The provisional successor source `b54e5419bb7a222822b14c3c2f0c0bff140661ea` preserves the thirteen-field binding schema version 1 and completes the declared client allowlist.
Launch and strict reattachment keep config-digest equality; changing either declared selector refuses reattachment.
The launcher does not retarget a bound session after a refusal.
Intentional end uses the recorded session, owner generation, host, and endpoint through the public `runtime end-session` operation.
The owner verifies the lease and retained resources, or proves a released owner and all resources absent before publishing its ended tombstone.
Current global config or caller selector drift does not replace those exact end proofs.
The control plane confirms the owner-ended receipt and separately confirms closure of the outer attachment.
An already agent-free outer pane still requires the same exact owner-ended receipt.
The binding, task metadata, instructions, and durable inbox remain intact after end.
No lifecycle text or key is sent as a teardown fallback.
These consumer paths have isolated fixture qualification against the provisional successor source.
Final reconciliation with the successor pipeline-delivered source and receipt remains required before integration/publication readiness.
Integrated mandatory destination acceptance remains separate.
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
