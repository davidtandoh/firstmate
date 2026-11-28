#!/usr/bin/env python3
"""Local task scratch lifecycle engine, standard library / Python 3.9.

Owners: scratch.json v1 = {version, scratch:[relative glob], worktree_cache:[name]};
retention-merge.json v1 = {version,url}; retention-local.json v1 =
{version,project,branch,head}; retention-complete.json v1 =
{version,completed_at,artifact,merged_pr,worktree,lease_released,declaration_sha256}.
task-retention-report.json v1 =
{version,generated_at,mode,home,tasks,visited_entries,shared_worktrees}.
Task rows contain task, bytes (null if unavailable), eligible_bytes and reason;
optional worktree/worktree_reason describe released-path attribution, paths
lists preview/audit destinations, and pruned marks a completed pruning pass.
Shared worktree rows contain path, tasks, bytes when measured, cache_bytes and
reason; ambiguous paths have zero attributed cache bytes and no per-task copy.
retention-removals.jsonl appends {event,task,path,bytes,at}, with event planned
before each unlink and removed afterward; timestamps are Unix seconds.
Receipts never imply current Done state: backlog reads are authoritative.
Start invalidates completion and landing receipts under the spawn metadata lock.
Complete refreshes the clock after confirmed delivery; local landing records
require their exact commit to remain on the recorded local default branch.
Control records and recorded artifacts are always evidence, even under '*'.
An open captain hold referencing a task ID, task path, or its merged PR blocks it.
Any task meta (including dead/uncertain endpoints) blocks pruning; only teardown
owns removing it. Legacy tasks have no completion receipt and stay report-only.

Bounds: 120s wall time, 128 MiB Python engine address space where supported,
2,000 candidates, 200 held tasks, 10s per task read, 200,000 visited entries,
depth 64, 32 patterns of <=256 characters,
1 MiB per control/backlog input and combined held details, 2 MiB report. Traversal streams directory
entries and never opens scratch contents. Limits/errors prevent deletion for
the affected task; a failed or incomplete hold scan prevents every deletion.
Candidate state and closed fields come from home-addressed show --full reads;
held IDs use only the first slug field of a count-checked bounded listing.
Missing candidates are ineligible; archive-only records do not prove current state.
Empty overrides use defaults; relative overrides resolve beneath absolute FM_HOME.
An absent config directory or task-retention file leaves report-only enabled.
Child commands retain the launcher's inherited address-space limits; the shared
process-group timeout bounds their runtime, not their memory.
No worktree is ever modified. Reports measure logical regular-file bytes.
"""
from __future__ import annotations

import argparse
import fnmatch
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time

from fm_record_io import RecordError, canonical, read_regular, safe_path
from fm_record_io import open_absolute_directory as directory

LIMIT = 1048576
WEEK = 7 * 86400
CONTROL = {'brief.md', 'report.md', 'scratch.json', 'retention-merge.json',
           'retention-complete.json', 'retention-local.json', 'retention-removals.jsonl'}
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
ID = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$')
CHILD_ADDRESS_SPACE = resource.getrlimit(resource.RLIMIT_AS)


class RetentionError(ValueError):
    """Uncertain eligibility or an unsafe record."""


class RetentionTimeout(RuntimeError):
    """Global deadline, deliberately not caught as a task-local error."""


def require(condition, message):
    if not condition:
        raise RetentionError(message)


def relative(value, glob=False):
    require(isinstance(value, str) and 0 < len(value) <= 256, 'invalid relative pattern')
    parts = value.split('/')
    require(not value.startswith('/') and all(p not in ('', '.', '..') for p in parts),
            'absolute path or traversal refused: ' + value)
    require(not any(ord(c) < 32 or ord(c) == 127 for c in value), 'control character refused')
    if not glob:
        require(not any(c in value for c in '*?[]'), 'literal path required')
    return parts


def read_json(path):
    safe_path(path.parent.parent, path)
    raw, _ = read_regular(path, LIMIT)
    value = json.loads(raw)
    require(isinstance(value, dict) and value.get('version') == 1, 'invalid record: ' + str(path))
    return value


def publish(path, value, exclusive=False, dry=False):
    safe_path(path.parent.parent, path)
    require(not path.is_symlink(), 'symlink destination refused')
    if dry:
        return str(path)
    data = canonical(value).encode()
    require(len(data) <= 2 * LIMIT, 'output exceeds bound')
    if exclusive:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
    else:
        fd, name = tempfile.mkstemp(prefix='.retention-', dir=str(path.parent))
        try:
            with os.fdopen(fd, 'wb') as out:
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    return str(path)


def declaration(task):
    value = read_json(task / 'scratch.json')
    require(set(value) == {'version', 'scratch', 'worktree_cache'}, 'invalid declaration fields')
    for field in ('scratch', 'worktree_cache'):
        require(isinstance(value[field], list) and len(value[field]) <= 32, 'invalid pattern list')
        for pattern in value[field]:
            parts = relative(pattern, glob=field == 'scratch')
            if field == 'worktree_cache':
                require(len(parts) == 1 and pattern not in ('.git',), 'cache must be a named directory')
    return value


def matches(path, pattern):
    parts, pats = path.split('/'), pattern.split('/')

    @lru_cache(maxsize=20000)
    def walk(i, j):
        if j == len(pats):
            return i == len(parts)
        if pats[j] == '**':
            return walk(i, j + 1) or (i < len(parts) and walk(i + 1, j))
        return i < len(parts) and fnmatch.fnmatchcase(parts[i], pats[j]) and walk(i + 1, j + 1)

    return walk(0, 0)


def selected(path, patterns):
    parts = path.split('/')
    return any(matches('/'.join(parts[:i]), pattern)
               for i in range(1, len(parts) + 1) for pattern in patterns)


class Budget:
    def __init__(self):
        self.entries = 0

    def visit(self, depth):
        self.entries += 1
        require(self.entries <= 200000 and depth <= 64, 'filesystem scan budget exceeded')


def scan(fd, budget, patterns=(), protected=(), prefix='', depth=0, device=None, allow_links=False):
    """Validate the entire task before pruning; count only regular-file bytes."""
    total = eligible = 0
    device = os.fstat(fd).st_dev if device is None else device
    with os.scandir(fd) as entries:
        for entry in entries:
            budget.visit(depth)
            info = entry.stat(follow_symlinks=False)
            path = prefix + entry.name
            if stat.S_ISLNK(info.st_mode) and allow_links:
                continue
            require(not stat.S_ISLNK(info.st_mode), 'symlink refused: ' + path)
            require(info.st_dev == device, 'filesystem boundary refused: ' + path)
            if stat.S_ISDIR(info.st_mode):
                child = os.open(entry.name, DIR_FLAGS, dir_fd=fd)
                try:
                    a, b = scan(child, budget, patterns, protected, path + '/', depth + 1, device, allow_links)
                    total += a
                    eligible += b
                finally:
                    os.close(child)
            else:
                require(stat.S_ISREG(info.st_mode), 'special file refused: ' + path)
                total += info.st_size
                if path not in protected and selected(path, patterns):
                    eligible += info.st_size
    return total, eligible


def prune(fd, task, patterns, protected, budget, audit, prefix='', depth=0, dry=False):
    """Unlink relative to pinned, no-follow directory fds; log each removal."""
    with os.scandir(fd) as entries:
        for entry in entries:
            budget.visit(depth)
            path = prefix + entry.name
            info = entry.stat(follow_symlinks=False)
            require(not stat.S_ISLNK(info.st_mode), 'symlink appeared during prune: ' + path)
            if stat.S_ISDIR(info.st_mode):
                child = os.open(entry.name, DIR_FLAGS, dir_fd=fd)
                try:
                    require(os.fstat(child).st_dev == os.fstat(fd).st_dev, 'mount appeared during prune')
                    prune(child, task, patterns, protected, budget, audit, path + '/', depth + 1, dry)
                finally:
                    os.close(child)
                # Empty scratch directories are harmless to retain. Avoid
                # deleting a directory that concurrently gained evidence.
            elif path not in protected and selected(path, patterns):
                require(stat.S_ISREG(info.st_mode), 'special file appeared during prune')
                audit('planned', path, info.st_size)
                if not dry:
                    os.unlink(entry.name, dir_fd=fd)
                    audit('removed', path, info.st_size)


def restore_child_address_space():
    if resource.getrlimit(resource.RLIMIT_AS) != CHILD_ADDRESS_SPACE:
        resource.setrlimit(resource.RLIMIT_AS, CHILD_ADDRESS_SPACE)


def run_child(*args, **kwargs):
    return subprocess.run(*args, preexec_fn=restore_child_address_space, **kwargs)


def command_output(command, env, timeout=15):
    with tempfile.TemporaryFile() as output:
        result = run_child(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        output.seek(0)
        raw = output.read(LIMIT + 1)
    require(result.returncode == 0 and len(raw) <= LIMIT, 'backlog read failed or exceeded bound')
    return raw.decode()


def task_row(env, task_id):
    require(ID.fullmatch(task_id), 'unsafe task ID')
    try:
        raw = command_output(['bash', str(Path(__file__).with_name('fm-tasks-axi.sh')),
                              'show', task_id, '--full'], env, timeout=10)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise RetentionError('task unavailable in backlog: ' + task_id + ': ' + str(error)) from error
    rows = {}
    for line in raw.splitlines():
        match = re.fullmatch(r'  ([a-z_]+): (.*)', line)
        if not match:
            continue
        key, value = match.groups()
        if key not in ('id', 'state', 'closed', 'hold_kind', 'hold_reason', 'body', 'links'):
            continue
        require(key not in rows, 'duplicate task field: ' + key)
        rows[key] = json.loads(value) if value.startswith('"') else value
        require(isinstance(rows[key], str), 'invalid task field: ' + key)
        require(not re.search(r'\n\.\.\. \(truncated, \d+ chars total - use .*--full', rows[key]),
                'truncated task detail: ' + task_id)
    require(rows.get('id') == task_id and rows.get('state') in ('queued', 'in_flight', 'done')
            and 'closed' in rows, 'invalid task state fields: ' + task_id)
    require({'hold_kind', 'hold_reason', 'body', 'links'} <= rows.keys(),
            'incomplete task detail: ' + task_id)
    return rows


def held_rows(env):
    # Only the unquoted slug before the first comma is read from this listing.
    # The wrapper projects IDs only; titles, bodies and notes are discarded.
    raw = command_output(['bash', str(Path(__file__).with_suffix('.sh')), 'held'], env)
    lines = raw.splitlines()
    counts = [re.fullmatch(r'count: (\d+)', line) for line in lines if line.startswith('count:')]
    require(len(counts) == 1 and counts[0] is not None, 'held task listing truncated or invalid')
    count = int(counts[0].group(1))
    require(count <= 200, 'held task bound exceeded')
    ids = []
    require(len(lines) == (count + 2 if count else 1), 'incomplete held task listing')
    if count:
        header = 'tasks[%d]{id,state,kind,repo,title}:' % count
        require(lines.count(header) == 1, 'invalid held task listing')
        start = lines.index(header) + 1
        for line in lines[start:start + count]:
            match = ID.fullmatch(line)
            require(match is not None, 'invalid held task ID')
            ids.append(match.group(0))
    require(len(ids) == count and len(set(ids)) == count, 'invalid held task count')
    rows = {}
    size = 0
    for task_id in ids:
        rows[task_id] = task_row(env, task_id)
        size += len(canonical(rows[task_id]).encode())
        require(size <= LIMIT, 'held task detail budget exceeded')
    return rows


def done_confirmed(task_id, rows, env):
    row = rows.get(task_id, {})
    return row.get('state') == 'done' and row.get('closed') not in (None, '', '-')


def local_landing(proof):
    require(set(proof) == {'version', 'project', 'branch', 'head'}, 'invalid local landing record')
    require(isinstance(proof['project'], str) and Path(proof['project']).is_absolute(), 'invalid local project')
    require(isinstance(proof['head'], str) and re.fullmatch(r'[0-9a-f]{40,64}', proof['head']), 'invalid local head')
    require(isinstance(proof['branch'], str), 'invalid local branch')
    result = run_child(['git', '-C', proof['project'], 'check-ref-format', 'refs/heads/' + proof['branch']],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    require(result.returncode == 0, 'invalid local branch')
    result = run_child(['git', '-C', proof['project'], 'merge-base', '--is-ancestor', proof['head'],
                             'refs/heads/' + proof['branch']],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    require(result.returncode == 0, 'local landing no longer on default branch')
    return proof


def current_reason(task_id, task, state, receipt, rows, env):
    require(set(receipt) == {'version', 'completed_at', 'artifact', 'merged_pr', 'worktree', 'lease_released', 'declaration_sha256'}
            and receipt.get('version') == 1 and type(receipt.get('completed_at')) is int,
            'invalid completion receipt')
    require(type(receipt.get('lease_released')) is bool, 'invalid lease receipt')
    for field in ('artifact', 'merged_pr', 'worktree'):
        require(receipt[field] is None or isinstance(receipt[field], str), 'invalid receipt field: ' + field)
    require(receipt['declaration_sha256'] == hashlib.sha256(canonical(declaration(task)).encode()).hexdigest(),
            'scratch declaration changed after completion')
    if not done_confirmed(task_id, rows, env):
        return 'task not confirmed Done in backlog'
    for other in rows.values():
        if other['state'] != 'done' and other['hold_kind'] == 'captain':
            text = canonical(other)
            if re.search(r'(?<![A-Za-z0-9_.-])' + re.escape(task_id) + r'(?![A-Za-z0-9_.-])', text):
                return 'open captain hold references task: ' + other['id']
            if receipt.get('merged_pr') and receipt['merged_pr'] in text:
                return 'open captain hold references deliverable: ' + other['id']
    if os.path.lexists(state / (task_id + '.meta')) or os.path.lexists(state / (task_id + '.backlog-close')):
        return 'endpoint or pending task record remains'
    if time.time() - receipt['completed_at'] < WEEK:
        return 'seven-day grace period not elapsed'
    artifact = receipt.get('artifact')
    merged = receipt.get('merged_pr')
    if artifact:
        relative(artifact)
        safe_path(task, task / artifact)
        read_regular(task / artifact, LIMIT, first_line=True)
    elif merged:
        proof = read_json(task / 'retention-merge.json')
        require(proof.get('url') == merged, 'merge receipt does not match completion')
    else:
        return 'deliverable unconfirmed'
    return ''


def worktree_report(receipt, decl, budget, inventory, task_id):
    path = receipt.get('worktree')
    if not path or not receipt.get('lease_released') or not os.path.lexists(path):
        return None
    # A pool slot may have been reassigned. Do not attribute its caches to the
    # old task when any owner claim now exists. It is still reported as uncertain.
    key = os.path.normpath(path)
    if key in inventory:
        previous = inventory[key]
        previous['tasks'].append(task_id)
        previous['report'].update(path=key, cache_bytes=0,
                                  reason='ambiguous worktree ownership; report only')
        return previous['report']
    marker = Path(path).parent / '.fm-slot-owner'
    if os.path.lexists(marker):
        result = {'path': path, 'cache_bytes': 0, 'reason': 'worktree claimed or lease uncertain; report only'}
    else:
        fd = directory(path)
        try:
            total, caches = scan(fd, budget, decl.get('worktree_cache', []), allow_links=True)
            result = {'path': path, 'bytes': total, 'cache_bytes': caches,
                      'symlinks': 'excluded without following', 'reason': 'released worktree remains; report only'}
        finally:
            os.close(fd)
    inventory[key] = {'tasks': [task_id], 'report': result}
    return result


def report(args, roots, env):
    data, state, config = roots
    destination = state / 'task-retention-report.json'
    if args.periodic and destination.exists():
        previous = read_json(destination)
        require(type(previous.get('generated_at')) is int, 'invalid report timestamp')
        if time.time() - previous['generated_at'] < WEEK:
            return None
    mode = 'report'
    if os.path.lexists(config / 'task-retention'):
        raw, _ = read_regular(config / 'task-retention', 32)
        mode = raw.decode().strip()
        require(mode in ('report', 'prune'), 'config/task-retention must be report or prune')
    try:
        holds = held_rows(env)
        hold_error = ''
    except (OSError, ValueError, RecordError, subprocess.TimeoutExpired) as error:
        holds = {}
        hold_error = 'captain hold scan incomplete: ' + str(error)
    budget = Budget()
    results = []
    worktrees = {}
    with os.scandir(data) as entries:
        for entry in entries:
            if args.locked_task and entry.name != args.locked_task:
                continue
            require(len(results) < 2000, 'task directory bound exceeded')
            if not entry.is_dir(follow_symlinks=False) and not entry.is_symlink():
                continue
            task_id, task = entry.name, data / entry.name
            row = {'task': task_id, 'bytes': None, 'eligible_bytes': 0, 'reason': ''}
            try:
                require(ID.fullmatch(task_id), 'unsafe task ID')
                fd = directory(task)
                try:
                    row['bytes'], _ = scan(fd, budget)
                    rows = dict(holds)
                    rows[task_id] = task_row(env, task_id)
                    if hold_error:
                        row['reason'] = hold_error
                    elif not os.path.lexists(task / 'scratch.json'):
                        row['reason'] = 'undeclared legacy data; decision required'
                    elif not os.path.lexists(task / 'retention-complete.json'):
                        row['reason'] = 'completion not recorded'
                    else:
                        decl = declaration(task)
                        receipt = read_json(task / 'retention-complete.json')
                        row['reason'] = current_reason(task_id, task, state, receipt, rows, env)
                        if done_confirmed(task_id, rows, env):
                            row['worktree'] = worktree_report(receipt, decl, budget, worktrees, task_id)
                        protected = CONTROL | {receipt.get('artifact', '')}
                        _, scratch = scan(fd, budget, decl['scratch'], protected)
                        if not row['reason']:
                            row['eligible_bytes'] = scratch
                            row['reason'] = 'eligible' if scratch else 'no declared scratch files remain'
                            if args.prune and mode == 'prune' and scratch:
                                row['paths'] = [str(task / 'retention-removals.jsonl')]
                                if args.dry_run:
                                    def preview(_event, path, _size):
                                        row['paths'].append(str(task / path))
                                        require(len(canonical(row).encode()) <= LIMIT, 'preview exceeds output budget')
                                    prune(fd, task, decl['scratch'], protected, budget, preview, dry=True)
                                elif not args.locked_task:
                                    locked = json.loads(command_output(
                                        ['bash', str(Path(__file__).with_suffix('.sh')), 'locked-prune', task_id], env, timeout=115))
                                    require(len(locked['tasks']) == 1, 'locked prune did not find task')
                                    row = locked['tasks'][0]
                                elif not args.dry_run:
                                    # Re-read all backlog/hold state immediately before
                                    # unlink, rather than trusting the report snapshot.
                                    fresh = held_rows(env)
                                    fresh[task_id] = task_row(env, task_id)
                                    reason = current_reason(task_id, task, state, receipt, fresh, env)
                                    require(not reason, reason)
                                    log_fd = os.open('retention-removals.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                                    try:
                                        log_info = os.fstat(log_fd)
                                        require(stat.S_ISREG(log_info.st_mode) and log_info.st_nlink == 1, 'unsafe audit log')

                                        def audit(event, path, size):
                                            line = canonical({'event': event, 'task': task_id, 'path': path, 'bytes': size, 'at': int(time.time())}).encode()
                                            require(os.write(log_fd, line) == len(line), 'short audit write')
                                            os.fsync(log_fd)

                                        prune(fd, task, decl['scratch'], protected, budget, audit)
                                    finally:
                                        os.close(log_fd)
                                    row['pruned'] = True
                finally:
                    os.close(fd)
            except (OSError, ValueError, RecordError, subprocess.TimeoutExpired) as error:
                row['eligible_bytes'] = 0
                row['reason'] = str(error)
            results.append(row)
    shared = []
    ambiguous_tasks = set()
    for key, entry in sorted(worktrees.items()):
        if len(entry['tasks']) > 1:
            shared.append(dict(entry['report'], tasks=sorted(entry['tasks'])))
            ambiguous_tasks.update(entry['tasks'])
    for row in results:
        if row['task'] in ambiguous_tasks:
            row['worktree'] = None
            row['worktree_reason'] = 'ambiguous ownership; see shared_worktrees'
    output = {'version': 1, 'generated_at': int(time.time()), 'mode': mode,
              'home': env['FM_HOME'], 'tasks': sorted(results, key=lambda r: r['task']),
              'visited_entries': budget.entries, 'shared_worktrees': shared}
    require(len(canonical(output).encode()) <= 2 * LIMIT, 'report exceeds bound')
    if args.periodic and not args.dry_run:
        publish(destination, output)
    elif args.periodic:
        output['would_write'] = str(destination)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('declare', 'complete', 'confirm-merge', 'confirm-local', 'start'):
        p = sub.add_parser(name)
        p.add_argument('task')
        p.add_argument('--dry-run', action='store_true')
        p.add_argument('--json', action='store_true')
        if name == 'declare':
            p.add_argument('--scratch', action='append', default=[])
            p.add_argument('--worktree-cache', action='append', default=[])
        elif name == 'confirm-local':
            p.add_argument('--project', required=True)
            p.add_argument('--branch', required=True)
            p.add_argument('--head', required=True)
        elif name != 'start':
            p.add_argument('--artifact')
            p.add_argument('--merged-pr')
            p.add_argument('--worktree')
            p.add_argument('--lease-released', action='store_true')
    p = sub.add_parser('report')
    for flag in ('json', 'prune', 'periodic', 'dry-run'):
        p.add_argument('--' + flag, action='store_true')
    p.add_argument('--locked-task', help=argparse.SUPPRESS)
    args = parser.parse_args()
    home = Path(os.path.abspath(os.environ.get('FM_HOME') or os.environ.get('FM_ROOT_OVERRIDE')
                                or Path(__file__).resolve().parent.parent))
    roots = tuple(home / (os.environ.get('FM_' + name + '_OVERRIDE') or name.lower())
                  for name in ('DATA', 'STATE', 'CONFIG'))
    checked_roots = (home, roots[0]) if args.command == 'declare' else (home,) + roots
    for root in checked_roots:
        try:
            fd = directory(root)
        except FileNotFoundError:
            if root == roots[2] and root not in (home, roots[0], roots[1]):
                continue
            raise
        os.close(fd)
    env = dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=str(roots[0]),
               FM_STATE_OVERRIDE=str(roots[1]), FM_CONFIG_OVERRIDE=str(roots[2]))
    if args.command == 'report':
        output = report(args, roots, env)
        if output is None:
            return
    else:
        require(ID.fullmatch(args.task), 'unsafe task ID')
        task = roots[0] / args.task
        fd = directory(task)
        os.close(fd)
        if args.command == 'start':
            paths = [task / name for name in ('retention-complete.json', 'retention-merge.json', 'retention-local.json')]
            for path in paths:
                safe_path(roots[0], path)
            for path in paths:
                if os.path.lexists(path) and not args.dry_run:
                    path.unlink()
            output = {'paths': [str(path) for path in paths]}
            print(canonical(output) if args.json else '\n'.join(output['paths']) + '\n', end='')
            return
        if args.command == 'declare':
            output = {'version': 1, 'scratch': args.scratch, 'worktree_cache': args.worktree_cache}
            require(len(args.scratch) <= 32 and len(args.worktree_cache) <= 32, 'too many patterns')
            for pattern in args.scratch:
                relative(pattern, glob=True)
            for name in args.worktree_cache:
                require(len(relative(name)) == 1 and name != '.git', 'cache must be a named directory')
            path = task / 'scratch.json'
        elif args.command == 'confirm-local':
            output = {'version': 1, 'project': args.project, 'branch': args.branch, 'head': args.head}
            local_landing(output)
            path = task / 'retention-local.json'
        elif args.command == 'confirm-merge':
            require(isinstance(args.merged_pr, str) and args.merged_pr.startswith('https://'), 'merge URL required')
            output = {'version': 1, 'url': args.merged_pr}
            path = task / 'retention-merge.json'
        else:
            rows = {args.task: task_row(env, args.task)}
            require(rows.get(args.task, {}).get('state') == 'done', 'completion requires task Done in backlog')
            artifact = args.artifact
            merged = None
            if artifact:
                relative(artifact)
                safe_path(task, task / artifact)
                read_regular(task / artifact, LIMIT, first_line=True)
                if artifact == 'retention-local.json':
                    require('local main' in canonical(rows[args.task]), 'local landing must be recorded in backlog')
                    local_landing(read_json(task / artifact))
                else:
                    require(artifact in canonical(rows[args.task]), 'artifact must be recorded in backlog')
            elif (task / 'retention-merge.json').exists():
                merged = read_json(task / 'retention-merge.json')['url']
                require(isinstance(merged, str) and merged in canonical(rows[args.task]),
                        'merged PR must be recorded in backlog')
            require(artifact or merged, 'confirmed deliverable required')
            require(not os.path.lexists(roots[1] / (args.task + '.meta')), 'endpoint record remains')
            output = {'version': 1, 'completed_at': int(time.time()), 'artifact': artifact,
                      'merged_pr': merged, 'worktree': args.worktree, 'lease_released': args.lease_released,
                      'declaration_sha256': hashlib.sha256(canonical(declaration(task)).encode()).hexdigest()}
            path = task / 'retention-complete.json'
        try:
            if args.command == 'confirm-merge' and os.path.lexists(path) and read_json(path) == output:
                destination = str(path)
            else:
                destination = publish(path, output, exclusive=args.command not in ('complete', 'confirm-merge'), dry=args.dry_run)
        except FileExistsError:
            if args.command != 'confirm-local':
                raise
            require(read_json(path) == output, 'conflicting local landing receipt')
            destination = str(path)
        output = {'path': destination, 'record': output}
    if args.json:
        print(canonical(output), end='')
    elif args.command == 'report':
        if 'would_write' in output:
            print('would write: ' + output['would_write'])
        for row in output['tasks']:
            print('{task}: bytes={bytes} eligible={eligible_bytes} {reason}'.format(**row))
            for path in row.get('paths', []):
                print(('  would touch: ' if args.dry_run else '  audit: ') + path)
            if row.get('worktree'):
                print('  worktree: ' + canonical(row['worktree']).strip())
            elif row.get('worktree_reason'):
                print('  worktree: ' + row['worktree_reason'])
        for shared in output['shared_worktrees']:
            print('shared worktree: ' + canonical(shared).strip())
    else:
        print(output['path'])


if __name__ == '__main__':
    def deadline_expired(_signal, _frame):
        raise RetentionTimeout('120s runtime budget exceeded')

    signal.signal(signal.SIGALRM, deadline_expired)
    signal.alarm(120)
    try:
        # Linux enforces address space. macOS may reject RLIMIT_AS; the bounded
        # streaming implementation still applies there and is measured in tests.
        try:
            soft, hard = CHILD_ADDRESS_SPACE
            capped = 128 * LIMIT if soft == resource.RLIM_INFINITY else min(soft, 128 * LIMIT)
            resource.setrlimit(resource.RLIMIT_AS, (capped, hard))
        except (ValueError, OSError):
            pass
        main()
    except (OSError, ValueError, RecordError, RetentionTimeout, subprocess.TimeoutExpired) as error:
        print('task-retention: ' + str(error), file=sys.stderr)
        sys.exit(1)
