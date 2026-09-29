# Omnigent verification

This record separates launch propagation, process liveness, native supervision, and trace export.
[Configuration](../configuration.md#omnigent-launch-mode-configomnigent--fm_omnigent) owns setup and limits; [architecture](../omnigent.md) owns component boundaries.

## Current empirical boundary

Observed on 2026-09-29 on macOS with the Kit-managed Omnigent `0.16.0.dev0 (d8208e80)`, commit `d8208e80779f442612cbeaaaa512a788914e2de5`, Codex `0.157.1`, and Herdr `0.9.1`.
The runtime was selected from the `state_file` returned by `agent-kit observe serve status --json`, under that file's parent directory at `runtime/bin/omnigent`.

A real Codex launch used `omnigent codex --server http://127.0.0.1:6767 --env FM_OMNIGENT_PROBE=launch-sentinel --env COMPACT_ADVISER_DISABLE=1 --prompt <probe> -- --disable hooks --dangerously-bypass-approvals-and-sandbox` with the status response's `client_environment`.
The probe ran this command in the native session:

```sh
printf 'OMNIGENT=%s FM_OMNIGENT_PROBE=%s COMPACT_ADVISER_DISABLE=%s\n' \
  "$OMNIGENT" "$FM_OMNIGENT_PROBE" "$COMPACT_ADVISER_DISABLE"
```

The native tool output was:

```text
OMNIGENT=1 FM_OMNIGENT_PROBE=launch-sentinel COMPACT_ADVISER_DISABLE=1
```

Herdr `pane process-info` reported a `python3.12` foreground process.
On macOS, that response contains the process name, `argv0`, and PID but omits the full arguments.
Reading that exact PID with `ps -o command= -p <pid>` showed the managed `python3`, the managed `omnigent` entrypoint, and `codex --server` in order.
After the shared classifier recognized that ordered shape, `bin/fm-control.sh probe exit` returned `stopped probe harness=codex backend=herdr` with the isolated endpoint and worktree.
The named lab helper completed teardown and verified the unchanged running default fleet.

This proves the native marker, explicit environment delivery, and one Codex control exit.
The later acceptance below extends launch and export evidence but exposes unresolved supervision failures.

## Codex primary-to-crewmate acceptance

On 2026-09-29, a wrapped Codex primary executed the real spawn entrypoint with `--relaunch --harness codex --model gpt-6-sol --effort low` for one preallocated, agent-free Herdr endpoint in an existing isolated worktree.
Using the replacement launch path avoided allocating or changing a shared worktree-pool slot.
This proves the primary-to-worker launch boundary, not fresh worktree allocation or the primary's watcher lifecycle.
The primary's tool process reported `OMNIGENT=1 FM_OMNIGENT=on`.
The spawn call removed `FM_OMNIGENT` from its own environment, so mode selection used the native `OMNIGENT=1` marker.
The worker's tool process reported:

```text
OMNIGENT=1 FM_OMNIGENT=on FM_TASK_ID=omni-codex-proof
```

Worker metadata recorded `harness=codex`, `omnigent=on`, `model=gpt-6-sol`, and `effort=low`.
The worker completed its initial request, then read and acknowledged a durable `fm-send` message by moving it into `handled/` and returning `OMNI_STEER_009_ACK`.

MLflow 3.15.2 stored an `agent:codex-native-ui` span with status `OK` for the worker.
The `agent.kit.session.transcript` attribute contained the actual user request and actual assistant response, distinguished by their `role` fields.
Both retained their respective `OMNI_REQUEST_009_CREW` and `OMNI_RESPONSE_009_CREW` markers and contained `[REDACTED]` in place of the synthetic password value.
The original synthetic value was absent from the span attributes.
The primary's trace contained its redacted request and an assistant commentary message; its final response marker was not present in the inspected transcript.
Presence of a requested response string inside a user prompt is not assistant-response evidence.

The verification used `MlflowClient.search_traces` scoped to experiment `1`, ``metadata.`mlflow.trace.session` = '<conversation-id>'``, and `span.name LIKE 'agent:%'`, then `MlflowClient.get_trace` for the matching trace.
It checked user and assistant items separately and retained counts and safe markers instead of raw exported transcripts.

## Remaining live boundaries

| Check | Observed result |
|---|---|
| Codex turn-end notification | The launch passed its `notify` command to the real Codex CLI, but neither the initial turn nor the steering turn created the notification file. |
| Codex control exit | The earlier environment probe exited successfully; the later completed worker's composer classified `unknown`, so `fm-control` refused to submit `/quit`. |
| Codex interrupt and relaunch | Not proven after the later composer refusal. |
| Claude 2.1.284 wrapper | The real Python wrapper classified as alive; native startup stopped at external-import consent. |
| Claude native supervision | Follow-up gated on the operator's [manual consent procedure](../configuration.md#claude-external-import-consent). |
| Kiro and Antigravity wrappers | Complete live matrix remains pending. |
| Remote secondmate | Propagation and destination service selection have portable coverage; no live remote-host acceptance is claimed. |

These results do not establish complete wrapped supervision.
The existing Codex semantic busy-state boundary also remains `unknown`; wrapping does not supply a verified busy source.
Test terminals were closed through Omnigent's session-scoped terminal resource API after control refusal, with empty terminal-list read-backs.
The named Herdr lab then passed helper teardown without a default-session tripwire failure.
That cleanup is not native `fm-control` exit evidence.

## Portable regression commands

```sh
LC_ALL=C LC_CTYPE=C bin/fm-test-run.sh \
  tests/fm-omnigent.test.sh \
  tests/fm-remote-secondmate-trace-context.test.sh \
  tests/fm-tmux-agent-liveness.test.sh
```

The local contract test executes the launch delivered to ship, scout, and secondmate panes and observes the explicit native arguments and environment at a service double.
It checks marker detection, home policy, malformed settings, service refusal before metadata publication, native opt-out, and dispatch preservation.
The SSH fixture executes the actual remote entrypoint and remote spawn, checks destination service resolution, and exercises recovery without an inherited marker.
The tmux test uses real Python processes with deliberately uninformative process names, plus server and unrelated-script negatives.
It covers both the observed script entrypoint and the supported exact `python -P -m omnigent.cli <harness>` form; the latter has no native-launch observation in this record.

## Live Herdr guard

```sh
HERDR_LAB_HELPER=/absolute/path/to/firstmate/bin/fm-herdr-lab.sh \
FM_OMNIGENT_LIVE=1 bin/fm-test-run.sh tests/fm-omnigent-live-e2e.test.sh
```

The guard uses a named non-default lab for every Herdr call, including control subprocesses, and tears it down through the same helper.
It checks installed Claude, Codex, Kiro, and Antigravity wrappers and reports absent optional harnesses explicitly.
It requires the actual Python wrapper to classify as an agent, then exercises the native exit through `fm-control`.
It submits no prompt and therefore makes no claim about busy hooks or export.
The token-free guard runs by default when its required tools are installed; `FM_OMNIGENT_LIVE=0` disables it.
An explicit `FM_OMNIGENT_LIVE=1` requires those tools and a healthy observation service.
The latest run passed Claude wrapper attribution, then failed at its external-import consent dialog before native exit.
Its first complete matrix run remains pending.
