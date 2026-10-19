---
name: fresh
description: Start a fresh main Firstmate Omnigent session when the captain invokes /fresh or asks to replace the current long-running session in one step.
user-invocable: true
metadata:
  internal: true
---

# fresh

Use this only in the main Claude primary running through Omnigent.
Workers, secondmates, and other primary harnesses must report the supported scope and keep their current session.

1. Load and complete the [stow skill](../stow/SKILL.md), including its completion receipt.
   If stow does not declare the session reset-safe, stop here and report its unresolved exception.
2. Run `bash bin/fm-fresh-session.sh` from the Firstmate code root with the current home environment.
   The script header and `--help` own launch, handoff, failure, and recovery mechanics.
3. A successful handoff closes this session.
   If the script reports failure, report its exact diagnostic and the owner it retained.
   If the replacement already owns the lock, keep this old session read-only.

Do not release the lock, close this session, or replace the script with manual lifecycle commands before the script confirms the replacement's ownership.
