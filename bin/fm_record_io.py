from __future__ import annotations

"""Bounded regular-file reads and canonical JSON for Firstmate record readers."""
import json
import os
import stat


class RecordError(ValueError):
    """A record violates its filesystem or byte-bound contract."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n'


def safe_path(root, path):
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise RecordError('symlink refused: {}'.format(current))


def read_regular(path, limit, tail=False, first_line=False):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise RecordError('not a regular file: {}'.format(path))
        truncated = info.st_size > limit
        if truncated and not tail and not first_line:
            raise RecordError('source exceeds byte limit: {}'.format(path))
        if truncated and tail:
            handle.seek(-limit, os.SEEK_END)
        raw = handle.readline(limit + 1) if first_line else handle.read(limit + 1)
        if len(raw) > limit:
            raise RecordError('source grew beyond read limit: {}'.format(path))
        if truncated and tail:
            raw = raw.partition(b'\n')[2]
        return raw, truncated
