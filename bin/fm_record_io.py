from __future__ import annotations

"""Shared no-follow directory traversal, bounded reads and canonical record JSON."""
import json
import os
import stat


class RecordError(ValueError):
    """A record violates its filesystem or byte-bound contract."""


def open_absolute_directory(path, label='directory'):
    path = os.fspath(path)
    if not os.path.isabs(path):
        raise RecordError('{} must be absolute: {}'.format(label, path))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0)
    fd = os.open(os.sep, flags)
    try:
        for part in (part for part in path.split(os.sep) if part):
            if part in ('.', '..'):
                raise RecordError('{} contains an unsafe component: {}'.format(label, path))
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


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
