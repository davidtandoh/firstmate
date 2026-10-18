import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
evidence = Path('/Users/davidtandoh/.no-mistakes/evidence/01M58C81PZ9RAQY7VQ1Y8X25ZS')
with tempfile.TemporaryDirectory(prefix='.direct-cli-', dir=root / 'tests') as tmp:
    base = Path(tmp)
    user = base / 'user'
    user.mkdir()
    env = {'PATH': os.environ['PATH'], 'HOME': str(user), 'TMPDIR': str(base),
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_AUTHOR_NAME': 'Validation', 'GIT_AUTHOR_EMAIL': 'validation@example.invalid',
           'GIT_COMMITTER_NAME': 'Validation', 'GIT_COMMITTER_EMAIL': 'validation@example.invalid',
           'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath', 'GIT_CONFIG_VALUE_0': '/dev/null'}
    log = []
    def run(args, payload=None, expected=0, extra=None):
        e = dict(env)
        e.update(extra or {})
        r = subprocess.run([str(a) for a in args], input=payload, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=e, timeout=30)
        log.append('$ ' + ' '.join(str(a) for a in args) + '\n' + r.stdout.decode() + '\nexit=' + str(r.returncode))
        assert r.returncode == expected, log[-1]
        return r.stdout.decode()
    try:
        home = base / 'receiver'
        home.mkdir()
        rel = 'config/crew-harness'
        def put(content, generation, expected=0):
            return run([root / 'bin/fm-remote-inherit.sh', 'put', rel, str(len(content)),
                        hashlib.sha256(content).hexdigest(), str(generation)],
                       content, expected, {'FM_HOME': str(home)})
        put(b'codex\n', 20)
        dest = home / rel
        record = home / 'config/.fm-inherit-crew-harness.generation'
        before = (dest.read_bytes(), dest.stat().st_mtime_ns, dest.stat().st_ino, record.read_bytes())
        assert 'generation=20' in put(b'codex\n', 4)
        assert before == (dest.read_bytes(), dest.stat().st_mtime_ns, dest.stat().st_ino, record.read_bytes())
        log.append('OBSERVED: identical older publication confirmed generation 20; destination bytes, inode, mtime and generation record unchanged.')
        assert 'superseded' in put(b'pi\n', 4, 1)
        assert dest.read_bytes() == b'codex\n' and record.read_bytes() == before[3]
        dest.write_bytes(b'local edit\n')
        assert 'superseded' in put(b'codex\n', 4, 1)
        assert dest.read_bytes() == b'local edit\n' and record.read_bytes() == before[3]
        log.append('OBSERVED: stale changed payload and destination drift both rejected; local content preserved.')
        origin = base / 'origin.git'
        seed = base / 'seed'
        code = base / 'code'
        mate = base / 'mate'
        run(['git', 'init', '--bare', '--initial-branch=main', origin])
        run(['git', 'clone', origin, seed])
        (seed / 'AGENTS.md').write_text('Validation home\n')
        (seed / 'bin').mkdir()
        (seed / 'bin/placeholder').write_text('local repository\n')
        (seed / '.gitignore').write_text('data/\nstate/\nconfig/\n.fm-secondmate-home\n')
        run(['git', '-C', seed, 'add', 'AGENTS.md', 'bin/placeholder', '.gitignore'])
        run(['git', '-C', seed, 'commit', '-m', 'Seed validation repository'])
        run(['git', '-C', seed, 'push', 'origin', 'main'])
        run(['git', 'clone', origin, code])
        run(['git', 'clone', origin, mate])
        (mate / '.fm-secondmate-home').write_text('mate\n')
        (code / 'data').mkdir()
        (code / 'state').mkdir()
        (code / 'data/secondmates.md').write_text('- mate - validation (home: ' + str(mate) + '; scope: x; projects: p; added 2026-10-18)\n')
        (seed / 'README.md').write_text('second revision\n')
        run(['git', '-C', seed, 'add', 'README.md'])
        run(['git', '-C', seed, 'commit', '-m', 'Advance validation repository'])
        run(['git', '-C', seed, 'push', 'origin', 'main'])
        extra = {'FM_HOME': str(code), 'FM_ROOT_OVERRIDE': str(code), 'FM_GUARD_READ_ONLY': '1'}
        old_mate = run(['git', '-C', mate, 'rev-parse', 'HEAD']).strip()
        out = run([root / 'bin/fm-update.sh', '--root-only'], extra=extra)
        assert 'firstmate: updated ' in out and 'secondmate mate:' not in out
        assert run(['git', '-C', mate, 'rev-parse', 'HEAD']).strip() == old_mate
        tip = run(['git', '-C', seed, 'rev-parse', 'HEAD']).strip()
        assert run(['git', '-C', code, 'rev-parse', 'HEAD']).strip() == tip
        log.append('OBSERVED: root-only update advanced the real local Git clone and left the registered secondmate untouched.')
        extra['FM_HOME'] = str(mate)
        out = run([root / 'bin/fm-remote-secondmate-control.sh', 'update', 'mate'], extra=extra)
        assert 'synced: ' + tip in out
        assert run(['git', '-C', mate, 'rev-parse', 'HEAD']).strip() == tip
        log.append('OBSERVED: real host-local update endpoint converged the secondmate to the root commit; no transport or backend stubs used. Remote SSH was not exercised.')
    finally:
        (evidence / 'direct-cli.log').write_text('\n\n'.join(log) + '\n')
print('Direct CLI checks passed; isolated homes and clones removed.')
