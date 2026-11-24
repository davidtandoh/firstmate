# Antigravity sync Test evidence

Target: db9a32e9f8e8603a4490f0e44fd3e9c9a60451b2
Base: 2f57f885309e80586e25510dabae180e2806714b

Result: inconclusive. Isolated executable-contract checks pass. Real Antigravity 1.5.15 launched, but both isolated authentication setups reached the sign-in screen before any prompt ran. Neither attempt proves the reported readiness failure fixed or reproduced. No credential changes or login actions were performed. The operator's normal login was not tested and is not declared unavailable.

## Commands and outcomes

All runner commands used --jobs 1 and saved complete stdout/stderr to the corresponding .log file.

- bin/fm-test-run.sh tests/fm-task-delivery.test.sh --jobs 1 --per-script-timeout-secs 90 --max-wall-ms 120000 --json <evidence>/delivery-timing.json: passed.
- bin/fm-test-run.sh tests/fm-agy-harness.test.sh --jobs 1 --per-script-timeout-secs 90 --max-wall-ms 120000 --json <evidence>/agy-harness-timing.json: failed because the missing-binary fixture found installed agy through Node's directory in PATH.
- Repaired tests/fm-agy-harness.test.sh with existing fm_test_base_path_sans. Repeated with --per-script-timeout-secs 120 --max-wall-ms 150000 --json <evidence>/agy-harness-fixed-timing.json: passed, including the missing-binary case, trust ordering, refusal and endpoint cleanup, model validation, and secondmate metadata.
- agy --version: 1.5.15. agy models reached the remote catalog and listed gemini-3.8-flash-low among other models. This is not authenticated prompt-processing evidence.
- FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh --jobs 1 --per-script-timeout-secs 900 --max-wall-ms 930000 --json <evidence>/agy-live-timing.json: real CLI reached sign-in using the test's copied .gemini HOME. Stopped the exact test PID with TERM at the credential blocker; runner recorded exit 143. No timeout occurred.
- Repeated the same live command with the operator's macOS credential-user-scope file also copied into the throwaway HOME. agy-live-scope-timing.json records exit 143 after stopping at the same sign-in screen. No timeout occurred.
- bin/fm-test-run.sh tests/fm-agy-primary.test.sh --jobs 1 --per-script-timeout-secs 180 --max-wall-ms 210000 --json <evidence>/agy-primary-timing.json: passed isolated primary and secondmate startup, hook decisions, bounded repair, pre-tool refusals, and supervision lifecycle checks. These use fixtures and are not real model acceptance.

<evidence> is this report's directory. The live commands set TMPDIR to .test-live-agy/tmp within the run worktree. Temporary wrappers forwarded to the installed /opt/homebrew/bin/agy and /opt/homebrew/bin/tmux, staged the macOS scope file on the second attempt, and recorded actual capture-pane output to agy-live-panes.txt. No CLI or model response was simulated. Each test used its own fm-agy-signals-<pid> tmux socket. Both lab servers and temporary stores were removed. Only the intended test repair remains in the worktree.

## Remaining acceptance

Provide a disposable test environment with working Antigravity authentication, or a supported way to reuse the normal login without writing operator state. Then drive actual Firstmate spawn through readiness and instruction completion, and run the live primary/secondmate hook checks. Authentication portability, not tool absence, prevented these checks here.

No rendered web UI was changed or exercised. The product evidence is the actual CLI terminal capture. Broad regression and hosted CI remain the outer executor's responsibility.
