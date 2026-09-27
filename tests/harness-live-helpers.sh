#!/usr/bin/env bash
# Installed binary resolution shared by the token-free harness liveness guards.
# Cursor delegates to its production identity owner. Other launchers use PATH,
# with the same home-local Kimi fallback as fm-spawn.sh.

fm_test_resolve_harness_binary() { # <harness>
  local harness=$1 candidate
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}
