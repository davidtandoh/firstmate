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

Herdr `pane process-info` reported a `python3.12` foreground process whose command line began with the managed `python3`, the managed `omnigent` entrypoint, and `codex --server`.
After the shared classifier recognized that ordered shape, `bin/fm-control.sh probe exit` returned `stopped probe harness=codex backend=herdr` with the isolated endpoint and worktree.
The named lab helper completed teardown and verified the unchanged running default fleet.

This proves the native marker, explicit environment delivery, and one Codex control exit.
It does not prove the complete Firstmate primary-to-worker workflow, Claude/Kiro/Antigravity live supervision, busy and turn-end hooks, steering, interrupt, relaunch, or end-to-end MLflow content export.
Those live acceptance checks remain pending a healthy observation service.
Do not treat the portable tests or the guard's registration as a live pass.

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
Its first complete matrix run is pending.
