#!/usr/bin/env python3
"""Bounded, canonical fm-velocity-facts.v1 collector; standard library only.

Reads only this home's state/*.status, state/*.meta, pending .wake-queue,
retained .watch-triage.log and .watch-deliveries.log, and data/backlog.md and
data/done-archive.md. No project traversal, subprocess execution of metadata,
session transcript reads, or fleet mutation. Metadata is data, never shell.

Bounds: 2000 state directory entries, 200 task ids, 256 KiB per source (tails
for append-only logs), 2000 events total, 10 forge calls, 2 MiB final JSON.
Limits fail closed except log tails, which disclose the omitted prefix.
Missing optional sources and unavailable forge data remain explicit gaps.
Sources are a best-effort sequential observation, not a transactional snapshot.

The collector owns these read and exclusive-output primitives because existing
Python record readers have no shared bounded no-follow filesystem interface.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

READ_LIMIT = 262144
OUTPUT_LIMIT = 2097152
EVENT_LIMIT = 2000
STATUS = re.compile(r'^([a-z][a-z-]*)(?:\s+corr=[0-9A-Fa-f]{16}|\s*\[[^\]\n]*\])*\s*:')
STAMP = re.compile(r'\[at=([0-9]+)\]')
PR = re.compile(r'https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)')


class FactsError(Exception):
    """A source or destination violates the collection contract."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n'


def safe_path(home, path):
    """Reject symlink components within the explicitly selected home."""
    relative = path.relative_to(home)
    current = home
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise FactsError('symlink refused: {}'.format(current))


def read_record(home, path, limitations, tail=False, limit=READ_LIMIT):
    safe_path(home, path)
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        limitations.append('missing: {}'.format(path.relative_to(home)))
        return ''
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise FactsError('not a regular file: {}'.format(path))
        truncated = info.st_size > limit
        if truncated and not tail:
            raise FactsError('source exceeds byte limit: {}'.format(path))
        if truncated:
            handle.seek(-limit, os.SEEK_END)
            limitations.append('tail only: {}'.format(path.relative_to(home)))
        raw = handle.read(limit + 1)
        if len(raw) > limit:
            raise FactsError('source grew beyond read limit: {}'.format(path))
        if truncated:
            raw = raw.partition(b'\n')[2]
        return raw.decode('utf-8')


def in_window(epoch, now):
    return now - 86400 <= epoch < now


def forge_times(url):
    """Read gh-axi's projected TOON scalar fields, not raw API payloads."""
    match = PR.fullmatch(url)
    if not match or not shutil.which('gh-axi'):
        return {'url': url, 'source': 'unavailable'}
    endpoint = '/repos/{}/{}/pulls/{}'.format(*match.groups())
    try:
        with tempfile.TemporaryFile() as output:
            result = subprocess.run(
                ['gh-axi', 'api', endpoint, '--jq', '{created_at,merged_at}'],
                stdout=output, stderr=subprocess.DEVNULL, timeout=5, check=False)
            output.seek(0)
            raw = output.read(8193)
        if result.returncode or len(raw) > 8192:
            raise FactsError('forge query failed or exceeded output limit')
        fields = {}
        for line in raw.decode('utf-8').splitlines():
            key, sep, value = line.partition(': ')
            if sep and key in ('created_at', 'merged_at'):
                if key in fields:
                    raise FactsError('duplicate forge field')
                fields[key] = json.loads(value)
        if set(fields) != {'created_at', 'merged_at'} or not isinstance(fields['created_at'], str):
            raise FactsError('unexpected forge response')
        for value in fields.values():
            if value is not None:
                if not isinstance(value, str):
                    raise FactsError('invalid forge timestamp')
                datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
        return dict(fields, url=url, source='gh-axi')
    except (OSError, subprocess.TimeoutExpired, ValueError, FactsError):
        return {'url': url, 'source': 'unavailable'}


def collect(home, now, include_prs):
    limitations = [
        'Retained records only; teardown and log rotation can remove activity.',
        'Status events describe declarations, not measured execution or current state.',
        'Backlog dated tags have day precision; no exact transition journal is available.',
        'Wake counts cover pending rows only, not all wakes in the last 24h.',
        'Delivery log has no delivery timestamp; notification count_24h is unmeasured.',
        'Sequential source reads are not a transactional snapshot.',
    ]
    state = home / 'state'
    safe_path(home, state)
    names = []
    if state.exists():
        with os.scandir(state) as entries:
            for entry in entries:
                names.append(entry.name)
                if len(names) > 2000:
                    raise FactsError('state directory exceeds 2000 entries')
    else:
        limitations.append('missing: state')
    ids = sorted({name.rsplit('.', 1)[0] for name in names
                  if not name.startswith('.') and name.endswith(('.meta', '.status'))})
    if len(ids) > 200:
        raise FactsError('task inventory exceeds 200 ids')
    tasks, urls, untimed, event_count = [], set(), 0, 0
    for task_id in ids:
        meta = {}
        seen_keys = set()
        for line in read_record(home, state / (task_id + '.meta'), limitations).splitlines():
            key, sep, value = line.partition('=')
            if not sep or key in seen_keys:
                raise FactsError('invalid or duplicate metadata key: {}'.format(task_id))
            seen_keys.add(key)
            if key in ('kind', 'harness', 'model', 'effort', 'mode', 'spawn_gen', 'pr'):
                meta[key] = value
        events, preceding = [], None
        for line in read_record(home, state / (task_id + '.status'), limitations, tail=True).splitlines():
            verb = STATUS.match(line)
            prefix = line.partition(':')[0]
            stamp = STAMP.search(prefix)
            if '[at=' in prefix and not stamp:
                raise FactsError('malformed status timestamp: {}'.format(task_id))
            if not verb:
                continue
            if not stamp:
                untimed += 1
                continue
            epoch = int(stamp.group(1))
            event = {'at': epoch, 'verb': verb.group(1), 'summary': line.split(':', 1)[1].strip()[:512]}
            if epoch < now - 86400:
                preceding = event
            elif in_window(epoch, now):
                events.append(event)
                event_count += 1
                if event_count > EVENT_LIMIT:
                    raise FactsError('status events exceed 2000')
            if in_window(epoch, now):
                urls.update(match.group(0) for match in PR.finditer(line))
        generation = re.fullmatch(r's([0-9]+)\.[0-9]+\.[0-9]+', meta.get('spawn_gen', ''))
        spawned_at = int(generation.group(1)) if generation else None
        # A ready report can still await review with no new worker declaration.
        # Retain metadata as context without interpreting it as current state.
        if events or meta:
            tasks.append({'id': task_id, 'meta': meta, 'spawned_at': spawned_at,
                          'preceding_event': preceding, 'events': events})
            if PR.fullmatch(meta.get('pr', '')):
                urls.add(meta['pr'])

    wakes = Counter()
    for line in read_record(home, state / '.wake-queue', limitations, tail=True).splitlines():
        fields = line.split('\t')
        if len(fields) != 5 or not fields[0].isdigit() or not fields[1].isdigit() or fields[2] not in ('signal', 'stale', 'check', 'heartbeat'):
            raise FactsError('malformed pending wake row')
        if in_window(int(fields[0]), now):
            wakes[fields[2]] += 1
    triage = Counter()
    for line in read_record(home, state / '.watch-triage.log', limitations, tail=True).splitlines():
        match = re.match(r'^\[([^]]+)\] ([^:]+)', line)
        if not match:
            continue
        epoch = int(datetime.strptime(match.group(1), '%Y-%m-%dT%H:%M:%S%z').timestamp())
        if in_window(epoch, now):
            triage[match.group(2)[:80]] += 1
    notifications = Counter()
    for line in read_record(home, state / '.watch-deliveries.log', limitations, tail=True).splitlines():
        fields = line.split('\t', 2)
        if len(fields) != 3:
            raise FactsError('malformed delivery row')
        kind = fields[2].partition(':')[0]
        notifications[kind if kind in ('signal', 'stale', 'check', 'heartbeat') else 'other'] += 1
    backlog = []
    days = {datetime.fromtimestamp(t, timezone.utc).date().isoformat() for t in (now - 86400, now - 1)}
    for name in ('backlog.md', 'done-archive.md'):
        section = ''
        for line in read_record(home, home / 'data' / name, limitations).splitlines():
            if line.startswith('## '):
                section = line[3:][:80]
            if line.startswith('- [') and any(day in line for day in days):
                backlog.append({'file': name, 'section': section, 'row': line[:1024]})
                if len(backlog) > 500:
                    raise FactsError('dated backlog rows exceed 500')
    if not include_prs:
        limitations.append('Live PR timestamps not requested; use --include-prs for recorded retained PRs.')
    if len(urls) > 10:
        limitations.append('Only the first 10 sorted recorded PR URLs were queried.')
    prs = [forge_times(url) if include_prs and index < 10 else {'url': url, 'source': 'not-queried'}
           for index, url in enumerate(sorted(urls))]
    return {'schema': 'fm-velocity-facts.v1', 'home': str(home),
            'window': {'start': now - 86400, 'end_exclusive': now}, 'tasks': tasks,
            'untimed_status_lines': untimed, 'wakes': {'pending_by_type': dict(wakes)},
            'triage_by_type': dict(triage),
            'notifications': {'count_24h': None, 'retained_by_type': dict(notifications)},
            'backlog_dated_rows': backlog, 'prs': prs, 'limitations': sorted(set(limitations))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', default=os.environ.get('FM_HOME', str(Path(__file__).resolve().parent.parent)))
    parser.add_argument('--now', type=int, default=int(time.time()))
    parser.add_argument('--include-prs', action='store_true')
    parser.add_argument('--reuse', action='store_true', help='validate and reuse an existing daily snapshot for a queue retry')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if args.now < 86400:
        raise FactsError('--now must be at least 86400')
    home = Path(args.home).resolve(strict=True)
    date = datetime.fromtimestamp(args.now, timezone.utc).date().isoformat()
    path = home / 'data' / 'velocity-audit' / date / 'facts.json'
    safe_path(home, path)
    existing = path.exists()
    if existing:
        if not args.reuse:
            raise FactsError('destination already exists: {}'.format(path))
        facts = json.loads(read_record(home, path, [], limit=OUTPUT_LIMIT))
        if not isinstance(facts, dict) or facts.get('schema') != 'fm-velocity-facts.v1' or facts.get('home') != str(home):
            raise FactsError('existing facts have invalid schema or home')
        window = facts.get('window')
        if not isinstance(window, dict):
            raise FactsError('existing facts have invalid window')
        end = window.get('end_exclusive')
        if type(end) is not int or window.get('start') != end - 86400 or datetime.fromtimestamp(end, timezone.utc).date().isoformat() != date:
            raise FactsError('existing facts have invalid window')
    if not args.dry_run and not existing:
        payload = canonical(collect(home, args.now, args.include_prs)).encode('utf-8')
        if len(payload) > OUTPUT_LIMIT:
            raise FactsError('facts exceed 2 MiB')
        path.parent.mkdir(parents=True, exist_ok=True)
        safe_path(home, path)
        # Publish complete JSON without replacing any existing day's evidence.
        with tempfile.NamedTemporaryFile(dir=str(path.parent), prefix='.facts-', delete=False) as handle:
            staging = Path(handle.name)
            try:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
                os.link(str(staging), str(path))
            finally:
                staging.unlink()
    result = {'path': str(path), 'dry_run': args.dry_run, 'reused': existing}
    action = 'up to date' if existing else 'created'
    if args.dry_run:
        action = 'would reuse' if existing else 'would create'
    if args.json:
        print(canonical(result), end='')
    else:
        print('{}: {}'.format(action, path))


if __name__ == '__main__':
    try:
        main()
    except (FactsError, OSError, ValueError) as error:
        print('fm-velocity-facts: {}'.format(error), file=sys.stderr)
        sys.exit(1)
