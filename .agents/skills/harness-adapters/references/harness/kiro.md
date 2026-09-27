# Kiro CLI (V3 and V2 engines)

Kiro's `kiro-cli` TUI, verified end to end on 2026-09-13 with kiro-cli 2.21.4 on Amazon Linux 2 through tmux on the V2 agent engine.
The V3 launch and hook wiring were added on 2026-09-26 against kiro-cli 2.24.1 on macOS from the installed V3 source and credit-free CLI checks only; no live V3 crewmate has run yet, so every V3 lifecycle fact below is unproven until the live canary in `../../../../../docs/verification/kiro.md` passes.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no kiro wake protocol.
`../../../../../docs/verification/kiro.md` owns how every fact below was established and what is still unproven.

## Engine selection

`config/kiro-engine` holds `v3` or `v2`; an absent file means `v3`, the engine the captain runs interactively with `kiro-cli --v3`.
Amazon Linux 2 supports only V2, so a home on that platform sets `v2`.
Any other value, or an unreadable file, refuses the kiro spawn before any pane, worktree, or record exists.
[`docs/configuration.md`](../../../../../docs/configuration.md#kiro-engine-configkiro-engine) owns the file contract.

The two engines share the launch shape, the per-task `KIRO_HOME`, the trust setting, and the two generated per-task hook scripts.
They differ in how kiro finds those scripts:

| | V2 | V3 |
|---|---|---|
| Agent | `--agent firstmate`, read from `KIRO_HOME/agents/` | none; V3 reads agents only from the real `~/.kiro/agents/` and the workspace |
| Hooks | embedded in the per-task agent config | one Firstmate-owned global pair in the real `~/.kiro/hooks/`, guarded by a worktree token pointer |
| What `KIRO_HOME` relocates | agents, settings, sessions | the V3 TUI's settings file and session history only |
| Task store | per-task | the real `~/.kiro/tasks/`, shared with every other V3 session |

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `kiro-cli` from `PATH`, refused if absent; the installed command is a toolbox/aim-sandbox wrapper whose foreground process name is exactly `kiro-cli`. |
| Launch | `kiro-cli chat --agent-engine <engine> [--agent firstmate] --model <id> --effort <level> --trust-all-tools "<brief>"` with the resolved absolute binary and `KIRO_HOME` relocated onto the per-task home; `--agent firstmate` appears on V2 only. The positional brief auto-submits with no extra Enter on V2; V3 accepts the same positional `[INPUT]` in its help, but its auto-submit is unproven live. No launch-then-confirm gate: like claude, the pane just launches. |
| Busy state | Claude-shaped hooks are the ONLY source: `userPromptSubmit` opens a turn and `stop` closes it (V3 maps these names onto its `UserPromptSubmit` and `Stop` triggers), written as the `kiro-hook` record in `../../../../../bin/fm-busy-lib.sh`. A kiro task with no record classifies `unknown missing`; the classifier never reads the pane for kiro. |
| Rendered tail | The busy composer row carries the harness-named phrase `Kiro is working`, then a separator glyph, then a mode hint of `Type to steer` and a `Ctrl+S to queue` toggle hint; idle shows `Trust All Tools active ... /quit to exit` or the `ask a question or describe a task` placeholder. This page describes that row rather than spelling it, because any pattern matching a live kiro pane also matches prose reproducing the row, so a worker quoting this page would otherwise acknowledge a submit that never landed. What is matched is the phrase plus whitespace plus the separator and nothing beyond it, never the bare phrase and never the bare `esc to cancel` token kiro shares with agy; the mode hint is not required because kiro's default mode renders a different one, and both separator values kiro's theme uses are accepted. A pane narrow enough to truncate the separator defers nothing, because the submit core sends Enter before it reads any acknowledgement, so the steer lands, the acknowledgement is missed, `../../../../../bin/fm-send.sh` exits nonzero as known-undelivered, and a retry duplicates it. That is the chosen direction, since a duplicate steer beats a silently lost one, and it is the same outcome that file already records for agy. It is a DELIVERY guard in `../../../../../bin/fm-composer-lib.sh`, never a worker state source, and its one consumer is the harness-less union in `FM_DELIVERY_BUSY_REGEX_DEFAULT` that the tmux submit core reads to acknowledge a submit; kiro declares no per-harness signature, because the harness-scoped readers are away-mode injection (primary) and pending-reply observation (secondmate) and kiro can be neither. |
| Turn end | The `stop` hook keeps the `state/<id>.turn-ended` notification touch. Like claude, `stop` does NOT fire on a manual Escape interrupt; kiro V2 exposes no verified StopFailure/SessionEnd equivalent, so an abnormal turn end leaves the record busy until the next `userPromptSubmit`, and the supervisor reads that record as provably working. |
| Exit | `/quit`, one Enter; the process exits and prints `Session ended.` then `Resume with: kiro-cli --resume-id <session-id>`. |
| Interrupt | Single `Escape`, which prints a `Cancelled ...` row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--trust-all-tools` auto-approves tool calls on both engines; its otherwise blocking confirmation modal is suppressed by the seeded `chat.disableTrustAllConfirmation` setting, which the V3 TUI also reads from `KIRO_HOME/settings/cli.json`. This matches the unattended posture of every other adapter (claude bypass by default, agy and devin dangerous modes). An explicit `--trust-tools=<list>` was rejected because any tool outside the list raises a confirmation prompt that an unattended pane never answers. |
| Marker | None; a live tool subprocess carries no `KIRO_*` identity variable. `KIRO_HOME` is a firstmate-set config-relocation path, not an identity. |
| Resume | The interactive-exit line prints `--resume-id <id>`, and sessions live under the per-task `KIRO_HOME`, so `--resume-id` (or `--resume` for the most recent from the cwd) resumes with context. Firstmate does not automate resume: the control plane's deterministic `relaunch` re-reads the durable brief, matching every other adapter. |
| Model | `--model <id>` with a bare catalog `model_id` from `kiro-cli chat --agent-engine <engine> --list-models -f json`, asked of the same engine the worker runs (for example `claude-opus-5`, `auto`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable, hung, or `model_id`-less listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high\|xhigh\|max`; the full shared vocabulary passes through (unlike agy, which omits `xhigh`/`max`). |
| Composer | Bare `›` (U+203A) agent-glyph row, the same glyph codex draws. The `ask a question or describe a task` placeholder is near-gray at luminance 158, drawn as truecolor `38;2;158;158;158` on a truecolor pane and as the palette index `38;5;247` - the identical grey - on a pane with no `COLORTERM`. The shared ghost strip removes both under its near-achromatic ceiling, so a real idle pane reads `empty` in either encoding (verified against a live capture with tmux's own descriptor). Before that ceiling existed the placeholder survived the strip and the pane read `pending`, which suppressed every steer; `../../../../../docs/verification/kiro.md` owns that history. kiro registers no entry in the fleet-wide idle-placeholder set, which changes no verdict here. |

## Out-of-tree agent config (the V2 turn-end wiring)

`--agent` is name-only: a config path is rejected, and discovery is the global `KIRO_HOME/agents/` dir plus the workspace `<cwd>/.kiro/agents/` dir.
On a name collision the WORKSPACE copy wins, so a target repo shipping `.kiro/agents/firstmate.json` would shadow the firstmate-owned per-task config and leave a worker with no hooks and a busy record nothing closes; kiro announces the conflict on the pane only, which nothing in firstmate reads, so a canonical kiro spawn refuses before launch when the resolved worktree holds that file, names it, and asks for it to be renamed or removed.
`../../../../../docs/verification/kiro.md` owns the measurement behind that precedence and records the alternative of renaming the per-task agent as follow-up work.
The workspace dir is inside the disposable worktree and must never be written, so `../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task agent config at `state/<id>.kiro-home/agents/firstmate.json` and reaches it by relocating `KIRO_HOME` onto `state/<id>.kiro-home` on the launch command, the gemini shape (a dedicated per-task config outside the project, reached through a config-pointer).
That same per-task home holds `settings/cli.json` seeding `chat.disableTrustAllConfirmation`, which suppresses the `--trust-all-tools` modal (the only blocker on a fresh launch).
Relocating `KIRO_HOME` moves the whole global config root (agents, settings, sessions), and on Amazon Linux 2 it leaves auth alone because auth lives in the XDG data dir (`~/.local/share/kiro-cli`), so the worker uses the operator's real sign-in while nothing in the captain's real `~/.kiro` is touched.
That path does not exist on macOS and where auth lives there is unestablished, so the untouched-by-relocation premise does not carry to macOS; see Credential precondition below.
Because the relocation is wholesale rather than gemini's additive single-file layer, the per-task home does not inherit the operator's global MCP servers, skills, or agents; the per-task agent config declares `tools: ["*"]` and the crewmate relies on built-in tools.
Each hook `command` in that config is a single-token absolute path to a script the spawn generates beside it under `state/<id>.kiro-home/hooks/`, so a hook runs the same whether kiro execs the command directly or hands it to a shell; the busy event, its `|| true` tolerance of a refused stale generation, and the turn-end touch all live inside the script.
No single token can carry whitespace under either interpretation, so a canonical kiro spawn refuses before launch when the resolved `state/<id>.kiro-home` path contains whitespace, naming that path and asking for a whitespace-free `FM_HOME` or `FM_STATE_OVERRIDE`; without the hooks kiro has no other state source, so a pane that could never clear its busy record is never started.
`../../../../../bin/fm-control-lib.sh` lists the agent config file and both hook scripts as retirement paths so a relaunch retires the incarnation's hooks; `../../../../../bin/fm-teardown.sh` removes the whole `state/<id>.kiro-home` directory.

## Global hook pair (the V3 turn-end wiring)

V3's agent service resolves agents, standalone hook files, and its task store from the process home directory, never from `KIRO_HOME`.
A per-task agent config would never load, so a V3 launch names no agent.
Instead `../../../../../bin/fm-spawn.sh` writes one Firstmate-owned hook file, `~/.kiro/hooks/firstmate-crew.json`, whose `UserPromptSubmit` and `Stop` hooks run two dispatchers beside it, `fm-kiro-user-prompt-submit` and `fm-kiro-stop`.
This is the grok shape: V3 runs every hook command with the session's cwd, and each dispatcher is a silent exit-0 no-op unless that cwd holds a `.fm-kiro-hook` pointer.
The pointer carries only a token.
The token must name an entry in the private `~/.kiro/hooks/fm-kiro.d/` registry, and that entry names this task's `state/<id>.kiro-home`, whose generated script then runs.
The indirection means a worker that edits its pointer can select only another registered task, never an arbitrary script.
The dispatchers print nothing on either stream and always exit 0, because V3 reads a Stop hook's exit 1 or a JSON block decision on stdout as an instruction to keep going.
The pointer is git-excluded.
Relaunch and teardown retire the token file, the registry entry, and the pointer; the shared hook file and dispatchers stay for other tasks.
A V3 spawn refuses before launch when `~/.kiro/hooks` contains whitespace, for the same single-token reason as the V2 rule.

Because the V3 session reads the real `~/.kiro`, a V3 crewmate also loads the captain's global steering, skills, MCP configuration, and every other global hook, such as Agent Kit hooks.
Those hooks fire in crewmates too.

## Credential precondition

A verified kiro worker ran under a signed-in account with no key export, on Amazon Linux 2, where the login lives in the XDG data dir.
On macOS the login lives in `~/Library/Application Support/kiro-cli`, outside `KIRO_HOME`, so a relocated `KIRO_HOME` keeps it on both engines; `../../../../../docs/verification/kiro.md` owns the evidence.
Treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `kiro-cli`, never `*kiro*`.
The macOS app bundle also ships separate `kiro-cli-chat` and `kiro-cli-term` executables, and V3 runs its TUI and agent service under bundled `bun` and `node` runtimes; whether the pane's foreground process stays named `kiro-cli` under V3 on macOS is unproven, and the live canary checks it.
No environment marker is promoted, and kiro does not clear an inherited `CLAUDECODE`, so the spawn clears foreign markers at the launch boundary and the ancestry arm decides.
kiro is deliberately absent from the primary-capable session-lock vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms a busy generation for kiro and embeds it in the hook commands, exactly like claude and gemini.
`fm_busy_classify` returns the `kiro-hook` record when a valid one exists and `unknown missing` when none does; it has no kiro pane arm, so a rendered footer never classifies a kiro worker.
An abnormal turn end therefore leaves the record busy until the next `userPromptSubmit` re-opens it, and the watcher reads that record as provably working.
V3 fires `Stop` after each agent turn; whether it also fires for a delegated subagent's turn in the same cwd, which would close the record early, is unproven.
Teardown removes the per-task home and retires the busy generation.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no kiro protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, exit, and resume on the V2 engine.

## Quota

Kiro serves several vendors' models on Kiro credits, so dispatch reads quota-axi's own `kiro` provider row, never `claude`.
quota-axi reports that row with unknown quota semantics and reads it only while no Kiro process or task is running, so while a Kiro crewmate works the row reads as busy and unknown.
The resolver therefore treats a kiro profile as eligible but unranked, with that uncertainty disclosed, as `../../quota-array-dispatch/SKILL.md` prescribes.
Known accepted race: a quota read that starts within about one second of a Kiro launch can run the V3 start-up sweep over the real `~/.kiro/tasks` and clear that new task's running status ([What KIRO_HOME relocates under V3](../../../../../docs/verification/kiro.md#what-kiro_home-relocates-under-v3)).
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
