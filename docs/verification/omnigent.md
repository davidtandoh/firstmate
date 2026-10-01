# Omnigent verification

This record separates launch propagation, process liveness, native supervision, and trace export.
[Configuration](../configuration.md#omnigent-launch-mode-configomnigent--fm_omnigent) owns setup and limits; [architecture](../omnigent.md) owns component boundaries.

## Current Codex acceptance

Observed on 2026-10-01 on macOS with Kit-managed Omnigent `0.16.0.dev0 (dc4f1ffa, built 2026-10-01T07:40:01Z)`, Codex `0.159.2`, Herdr `0.9.1`, and MLflow SDK `3.15.2`.
`agent-kit observe serve status --json` reported `running` with `server_url=http://127.0.0.1:6767`.
The launcher selected the managed runtime from the status response's `state_file` and used its `client_environment`.

An isolated home and preallocated, agent-free endpoint in a named Herdr lab ran:

```sh
FM_OMNIGENT=on bin/fm-spawn.sh omni-codex-proof --relaunch \
  --harness codex --model gpt-6-sol --effort low
```

The launch started with `LC_ALL=C LC_CTYPE=C` and used the existing isolated worktree without allocating or changing a shared worktree-pool slot.
The worker ran a bounded environment probe, sent `OMNI_WORKING_013` as commentary, and returned a distinct `OMNI_FINAL_013` final reply.
The native tool output was:

```text
OMNIGENT=1 FM_OMNIGENT=on FM_TASK_ID=omni-codex-proof
```

The task's turn-end hook created `state/omni-codex-proof.turn-ended` automatically.
Neither the probe nor the worker wrote that marker directly.
`bin/fm-control.sh omni-codex-proof exit` returned `stopped omni-codex-proof harness=codex backend=herdr` with the isolated endpoint and worktree.
The backend then reported `dead`, and the conversation's terminal resource list was empty.
The named lab helper completed teardown and verified the unchanged running default fleet.

MLflow at `http://127.0.0.1:5051` retained trace `tr-9c4e2a47c104c2c4d10ea55381125437`, status `OK`, with an `agent:codex-native-ui` span for conversation `0877157ea5174f0fa580781a779c7d64`.

| Field | Observed value |
|---|---|
| `trace.data.request` | Contains `OMNI_REQUEST_013` and `password=[REDACTED]`. |
| `trace.data.response` | JSON string `"OMNI_FINAL_013 password=[REDACTED]"`. |
| Agent span `output.value` | Native final reply `OMNI_FINAL_013 password=[REDACTED]`. |
| Agent span `agent.kit.session.transcript` | Separate user request and assistant final-reply items, with synthetic password redaction. |

The working-note marker was absent from both response fields.
The original synthetic password value was absent from the request, response, and agent span attributes.
The check read the actual response fields and role-separated transcript items; a requested reply quoted inside a user prompt cannot satisfy it.

The verification used `MlflowClient(tracking_uri='http://127.0.0.1:5051')` with this session-scoped query:

```python
client.search_traces(
    locations=['1'],
    filter_string="metadata.`mlflow.trace.session` = '0877157ea5174f0fa580781a779c7d64'",
    max_results=100,
    page_token=page_token,
)
```

The verifier bounded pagination to ten pages and selected the `agent:` span with a matching `session.id`.
The successful query returned 46 traces, including terminal transport traces; checking only the ten newest traces would miss the agent result.
This proves final-response export for the tested worker and runtime versions; the Kit owns the export implementation.

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

This run used Omnigent `0.16.0.dev0 (d8208e80)` and Codex `0.157.1`.
The current acceptance above verifies the later runtime's turn-end, exit, and final-response boundaries with one worker; it does not repeat the primary's watcher lifecycle.

## Wrapper attribution and composer boundary

On 2026-09-29, Herdr `pane process-info` reported a `python3.12` foreground wrapper.
On macOS, that response contains the process name, `argv0`, and PID but omits the full arguments.
Reading that exact PID with `ps -o command= -p <pid>` showed the managed `python3`, the managed `omnigent` entrypoint, and `codex --server` in order.
The shared classifier recognized that ordered shape.

A paired capture on 2026-09-29 found the native `›` glyph in Codex's own tmux screen and an underscore in the outer Herdr screen.
The attaching tmux client reported `client_utf8=0` under `LC_ALL=C`.
Reattaching that same terminal with `LC_ALL=en_US.UTF-8` restored the glyph; the unchanged shared composer classifier returned `empty`, and `fm-control exit` returned `stopped`.
Firstmate now selects an installed UTF-8 locale for the attaching client.
The portable fixture keeps an underscore composer `unknown` and proves that real drafts remain `pending` beside the Omnigent footer.
The live guard deliberately launches from an ASCII supervisor locale.
The current acceptance above confirms a fresh native launch and control exit from that ASCII supervisor locale.

## Remaining live boundaries

| Check | Observed result |
|---|---|
| Codex turn-end notification and control exit | Passed on the current runtime above. |
| Codex interrupt and recovery | The replacement launch path passed on an agent-free endpoint; interrupt and replacement of a running worker remain unverified. |
| Claude 2.1.284 wrapper | The real Python wrapper classified as alive; native startup stopped at external-import consent. |
| Claude native supervision | Follow-up gated on the operator's [manual consent procedure](../configuration.md#claude-external-import-consent). |
| Kiro and Antigravity wrappers | Complete live matrix remains pending. |
| Remote secondmate | Propagation and destination service selection have portable coverage; no live remote-host acceptance is claimed. |

These results do not establish complete wrapped supervision.
The existing Codex semantic busy-state boundary also remains `unknown`; wrapping does not supply a verified busy source.
The earlier Claude test terminal was closed through Omnigent's session-scoped terminal resource API with an empty terminal-list read-back.
That cleanup is not Claude native `fm-control` exit evidence.

## Portable regression commands

```sh
LC_ALL=C LC_CTYPE=C bin/fm-test-run.sh \
  tests/fm-omnigent.test.sh \
  tests/fm-composer-lib.test.sh \
  tests/fm-remote-secondmate-trace-context.test.sh \
  tests/fm-tmux-agent-liveness.test.sh
```

The local contract test executes the launch delivered to ship, scout, and secondmate panes and observes the explicit native arguments and environment at a service double.
It checks marker detection, home policy, malformed settings, service refusal before metadata publication, ordinary native launches, backend propagation, dispatch preservation, and the attaching client's UTF-8 locale.
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
