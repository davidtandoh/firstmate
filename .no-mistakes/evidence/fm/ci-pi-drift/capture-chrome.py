#!/usr/bin/env python3
from __future__ import annotations
import os
from pathlib import Path
import shutil
import sys
from urllib.parse import unquote, urlparse

evidence = Path(__file__).parent
for arg in sys.argv[1:]:
    if arg.startswith("file://"):
        source = Path(unquote(urlparse(arg).path))
        export = source.parent / "calm-export.html"
        if source.name == "conversation-probe.html" and export.is_file():
            for name in ["calm-export.html", "conversation-probe.html", "calm-session.jsonl", "hidden.txt", "default.txt", "export.txt"]:
                item = source.parent / name
                if item.is_file() and not item.is_symlink() and item.stat().st_size < 20000000:
                    shutil.copyfile(item, evidence / name)
os.execv("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", *sys.argv[1:]])
