from __future__ import annotations

"""Task-bound Codex completion evidence, canonical failures and retry receipts.

Called through fm-codex-native.sh, which owns the metadata lock and generation
validation. No global native-session search. Wrapped binding prefers
HARNESS_CODEX_NATIVE_BRIDGE_DIR; otherwise exactly CODEX_HOME's parent is tried.
The bridge must name that private CODEX_HOME and the task's current worktree.
Only the bound canonical rollout is read (three UUID-derived dates, at most
4096 entries per date, 1 MiB header and 512 KiB tail). Unknown or unsafe
evidence fails closed.
Direct notify initially binds only a completion of the exact launch brief.
One overload retry receipt is allowed per spawn generation, before delivery.
The receipt survives uncertain delivery, so recovery cannot double-submit.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import uuid

from fm_record_io import canonical, read_regular, safe_path

LIMIT = 524288
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,199}\Z')


class NativeError(ValueError):
    """Native identity or evidence could not be established."""


def load(path, limit=LIMIT):
    value = json.loads(read_regular(path, limit)[0])
    if not isinstance(value, dict):
        raise NativeError('expected JSON object')
    return value


def publish(path, value):
    safe_path(path.parent, path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(canonical(value))
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def token(value):
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise NativeError('invalid native identity')
    return value


def metadata(args):
    raw = read_regular(args.meta, 65536)[0].decode('utf-8')
    values = {}
    for line in raw.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in values:
            raise NativeError('malformed or duplicate metadata field')
        values[key] = value
    if values.get('spawn_gen') != args.gen or values.get('harness') != 'codex':
        raise NativeError('task generation or harness mismatch')
    if not Path(values.get('worktree', '')).is_absolute():
        raise NativeError('missing worktree')
    return values


def bridge_binding(meta):
    home = os.environ.get('CODEX_HOME', '')
    supplied = os.environ.get('HARNESS_CODEX_NATIVE_BRIDGE_DIR', '')
    if not home or not Path(home).is_absolute():
        raise NativeError('missing private CODEX_HOME')
    bridge = Path(supplied) if supplied else Path(home).parent
    if not bridge.is_absolute():
        raise NativeError('invalid bridge directory')
    safe_path(bridge.parent, bridge / 'state.json')
    state = load(bridge / 'state.json')
    if state.get('codex_home') != home or state.get('cwd') != meta['worktree']:
        raise NativeError('bridge CODEX_HOME or worktree mismatch')
    return {'bridge': str(bridge), 'codex_home': home,
            'thread_id': token(state.get('thread_id')), 'session_id': token(state.get('session_id'))}


def validate_binding(args, meta, binding):
    if binding.get('generation') != args.gen or binding.get('worktree') != meta['worktree']:
        raise NativeError('stale task binding')
    token(binding.get('thread_id'))
    if binding.get('bridge'):
        bridge = Path(binding['bridge'])
        safe_path(bridge.parent, bridge / 'state.json')
        state = load(bridge / 'state.json')
        for key in ('thread_id', 'codex_home', 'session_id'):
            if state.get(key) != binding.get(key):
                raise NativeError('native bridge identity changed')
        if state.get('cwd') != meta['worktree']:
            raise NativeError('native bridge worktree changed')
        return state.get('active_turn_id')
    if meta.get('omnigent') == 'on':
        raise NativeError('wrapped task has no bridge binding')
    return None


def latest_turn(binding, meta):
    home = Path(binding['codex_home'])
    # UUIDv7 embeds creation time. Check adjacent calendar dates for timezone
    # boundaries, without enumerating unrelated session years or native homes.
    identity = uuid.UUID(binding['thread_id'])
    if identity.version != 7:
        raise NativeError('canonical thread is not a UUIDv7')
    created = datetime.fromtimestamp(int(identity.hex[:12], 16) / 1000, timezone.utc)
    paths = []
    for offset in (-1, 0, 1):
        day = home / 'sessions' / (created + timedelta(days=offset)).strftime('%Y/%m/%d')
        safe_path(home, day)
        try:
            with os.scandir(str(day)) as entries:
                for count, entry in enumerate(entries):
                    if count >= 4096:
                        raise NativeError('canonical date directory exceeds entry bound')
                    if entry.name.startswith('rollout-') and entry.name.endswith('-' + binding['thread_id'] + '.jsonl'):
                        paths.append(Path(entry.path))
                        if len(paths) > 1:
                            raise NativeError('ambiguous canonical rollout')
        except FileNotFoundError:
            continue
    if not paths:
        raise NativeError('canonical rollout unavailable')
    path = paths[0]
    safe_path(home, path)
    header = json.loads(read_regular(path, 1048576, first_line=True)[0])
    if not isinstance(header, dict) or not isinstance(header.get('payload'), dict):
        raise NativeError('invalid canonical rollout header')
    if header.get('type') != 'session_meta' or header.get('payload', {}).get('id') != binding['thread_id'] or header['payload'].get('cwd') != meta['worktree']:
        raise NativeError('canonical rollout identity mismatch')
    raw, _ = read_regular(path, LIMIT, tail=True)
    latest = None
    for line in raw.splitlines():
        record = json.loads(line)
        if not isinstance(record, dict):
            raise NativeError('invalid canonical rollout record')
        payload = record.get('payload', {})
        if not isinstance(payload, dict):
            raise NativeError('invalid canonical rollout payload')
        if record.get('type') == 'event_msg' and payload.get('type') in ('task_started', 'task_complete', 'turn_aborted'):
            token(payload.get('turn_id'))
            latest = payload
    if latest is None:
        raise NativeError('no canonical turn boundary')
    return latest


def evidence(args, meta):
    binding = load(args.binding)
    active = validate_binding(args, meta, binding)
    latest = latest_turn(binding, meta)
    if active is not None and active != latest['turn_id']:
        return {'state': 'unknown'}
    error = latest.get('error')
    if latest['type'] != 'task_complete' or not error:
        return {'state': 'unknown'}
    if not isinstance(error, dict):
        raise NativeError('invalid canonical turn error')
    code = error.get('codex_error_info')
    # Current Codex also represents some error variants as tagged objects.
    if isinstance(code, dict) and len(code) == 1:
        code = next(iter(code))
    code = token(code)
    message = error.get('message')
    if not isinstance(message, str):
        raise NativeError('invalid canonical error message')
    message = ''.join(c if c.isprintable() else ' ' for c in message)[:500]
    return {'state': 'failed', 'code': code, 'message': message,
            'thread_id': binding['thread_id'], 'turn_id': latest['turn_id'], 'generation': args.gen}


def notify(args, meta):
    if len(args.payload.encode('utf-8')) > LIMIT:
        raise NativeError('oversized notify payload')
    payload = json.loads(args.payload)
    if not isinstance(payload, dict):
        raise NativeError('expected notification object')
    if payload.get('type') != 'agent-turn-complete' or payload.get('cwd') != meta['worktree']:
        raise NativeError('unbound notification')
    thread = token(payload.get('thread-id'))
    turn = token(payload.get('turn-id'))
    try:
        binding = load(args.binding)
        if binding.get('generation') == args.gen:
            validate_binding(args, meta, binding)
    except FileNotFoundError:
        binding = None
    # Replacing an old-generation binding is safe only inside the metadata lock.
    if binding is not None and binding.get('generation') != args.gen:
        binding = None
    if binding is None:
        if meta.get('omnigent') == 'on':
            binding = bridge_binding(meta)
        else:
            brief = read_regular(args.brief, LIMIT)[0].decode('utf-8').rstrip('\n')
            inputs = payload.get('input-messages')
            if inputs != ['\u2063FIRSTMATE_OP: v1 launch-brief: ' + brief]:
                raise NativeError('direct notification does not complete the launch brief')
            home = os.environ.get('CODEX_HOME', '')
            if not Path(home).is_absolute():
                raise NativeError('direct CODEX_HOME missing')
            binding = {'thread_id': thread, 'codex_home': home}
        binding.update(generation=args.gen, worktree=meta['worktree'])
        publish(args.binding, binding)
    if meta.get('omnigent') == 'on':
        callback_binding = bridge_binding(meta)
        if any(binding.get(key) != value for key, value in callback_binding.items()):
            raise NativeError('callback bridge differs from task binding')
    # An auxiliary callback can establish a bridge binding, never completion.
    if thread != binding['thread_id']:
        return {'accepted': False, 'reason': 'auxiliary-thread'}
    active = validate_binding(args, meta, binding)
    if active is not None and active != turn:
        return {'accepted': False, 'reason': 'different-active-turn'}
    deadline = time.monotonic() + 2
    while True:
        latest = latest_turn(binding, meta)
        if latest['type'] == 'task_complete' and latest['turn_id'] == turn:
            break
        if time.monotonic() >= deadline:
            return {'accepted': False, 'reason': 'no-canonical-completion'}
        time.sleep(0.05)
    # Store the generation and turn identity in the notification itself. The
    # watcher treats its content as opaque, so duplicate delivery is inert.
    event = {'generation': args.gen, 'thread_id': thread, 'turn_id': turn}
    marker = args.state / (args.id + '.turn-ended')
    try:
        if load(marker) == event:
            return {'accepted': True, 'duplicate': True}
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    publish(marker, event)
    return {'accepted': True, 'duplicate': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('notify', 'read', 'claim-retry'))
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--id', required=True)
    parser.add_argument('--gen', required=True)
    parser.add_argument('--meta', required=True, type=Path)
    parser.add_argument('--brief', type=Path)
    parser.add_argument('--payload')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    token(args.id)
    token(args.gen)
    args.binding = args.state / (args.id + '.codex-native.json')
    try:
        safe_path(args.meta.parent if args.operation == 'read' else args.state, args.meta)
        safe_path(args.state, args.binding)
        meta = metadata(args)
        if args.dry_run:
            print(canonical({'paths': [str(args.binding), str(args.state / (args.id + '.turn-ended')),
                                       str(args.state / (args.id + '.codex-retry.json'))]}), end='')
            return 0
        if args.operation == 'notify':
            if args.brief is None or args.payload is None:
                raise NativeError('notify requires brief and payload')
            result = notify(args, meta)
        else:
            result = evidence(args, meta)
            if args.operation == 'claim-retry':
                if result.get('code') != 'server_overloaded':
                    raise NativeError('no retryable canonical overload')
                receipt = args.state / (args.id + '.codex-retry.json')
                try:
                    if load(receipt).get('generation') == args.gen:
                        raise NativeError('overload retry already consumed for this task generation')
                except FileNotFoundError:
                    pass
                publish(receipt, result)
        print(canonical(result), end='')
        return 0
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        if args.operation == 'read':
            print(canonical({'state': 'unknown'}), end='')
            return 0
        print('error: Codex native evidence: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
