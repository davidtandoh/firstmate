#!/usr/bin/env python3
from __future__ import annotations

"""Relay one wrapper's stderr and name only its fresh, exact-server session.

Private process-substitution reader for fm-omnigent.sh, not a launch owner.
Input remains byte-for-byte stderr. Only the first Web UI record is eligible;
the shell owner verifies the session API and performs its bounded PATCH.
After the 180-second record deadline, relay continues without further naming.
The test-only wait override requires FM_TEST_SEAM=1.
"""

import argparse
import os
import re
import selectors
import subprocess
import threading
import time


def report(message: str) -> None:
    os.write(2, ("error: Omnigent session title: " + message + "\n").encode())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--started", required=True)
    parser.add_argument("--launcher", required=True)
    args = parser.parse_args()
    wait = 180
    if os.environ.get("FM_TEST_SEAM") == "1":
        value = os.environ.get("FM_TEST_OMNIGENT_TITLE_WAIT", "180")
        if not value.isdigit() or not 1 <= int(value) <= 180:
            report("invalid test record deadline")
            return 1
        wait = int(value)
    deadline = time.monotonic() + wait
    record = re.compile(rb"Web UI: " + re.escape(args.server.rstrip("/").encode())
                        + rb"/c/([a-f0-9]{32})")
    ansi = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
    pending = bytearray()
    discarded = False
    observing = True
    naming = None

    def name_session(session_id: str) -> None:
        # All requests and their deadlines remain with the shell launch owner.
        try:
            result = subprocess.run(
                ["bash", args.launcher, "_title-session", args.server, session_id,
                 args.harness, args.title, args.started],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=180,
                check=False,
            )
            if result.returncode < 0:
                report("naming request was interrupted")
        except (OSError, subprocess.TimeoutExpired) as error:
            report("naming request failed: " + type(error).__name__)

    # A separate request thread prevents a slow API from delaying stderr or
    # terminal attach. No terminal bytes, shared logs or session lists are read.
    with selectors.DefaultSelector() as selector:
        selector.register(0, selectors.EVENT_READ)
        while True:
            if observing and time.monotonic() >= deadline:
                report("timed out waiting for this launch's session record")
                observing = False
                pending.clear()
            timeout = max(0, deadline - time.monotonic()) if observing else None
            if not selector.select(timeout):
                continue
            data = os.read(0, 8192)
            if not data:
                if observing:
                    report("launch ended without a session record")
                break
            # os.write may write fewer bytes than requested even on a pipe.
            remaining = memoryview(data)
            while remaining:
                remaining = remaining[os.write(2, remaining):]
            if not observing:
                continue
            for byte in data:
                if byte in (10, 13):
                    line = ansi.sub(b"", bytes(pending))
                    pending.clear()
                    was_discarded, discarded = discarded, False
                    if was_discarded or not line.startswith(b"Web UI: "):
                        continue
                    observing = False
                    match = record.fullmatch(line)
                    if match is None:
                        report("invalid or wrong-server launch session record")
                    else:
                        naming = threading.Thread(
                            target=name_session, args=(match[1].decode("ascii"),)
                        )
                        naming.start()
                    break
                if not discarded:
                    if len(pending) == 4096:
                        pending.clear()
                        discarded = True
                    else:
                        pending.append(byte)
    if naming is not None:
        naming.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
