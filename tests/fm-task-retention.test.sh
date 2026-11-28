#!/usr/bin/env bash
# Fixture-only task scratch lifecycle, path safety, hold, and pruning tests.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { echo 'ok - skipped (tasks-axi required)'; exit 0; }
export ROOT
python3 - <<'PY'
import json
import os
import resource
import shutil
import sys
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class Retention(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        for name in ('data/job', 'state', 'config', 'user'):
            (self.home / name).mkdir(parents=True)
        (self.home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 100\n')
        (self.home / 'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
        self.env = dict(os.environ, HOME=str(self.home / 'user'), FM_HOME=str(self.home),
                        FM_ROOT_OVERRIDE='', FM_DATA_OVERRIDE=str(self.home / 'data'),
                        FM_STATE_OVERRIDE=str(self.home / 'state'),
                        FM_CONFIG_OVERRIDE=str(self.home / 'config'),
                        FM_PROJECTS_OVERRIDE=str(self.home / 'projects'))
        self.env.pop('TASKS_AXI_FILE', None)
        self.env.pop('TASKS_AXI_BACKEND', None)
        self.task('add', 'job', 'Retention fixture')
        self.task('done', 'job', '--report', 'data/job/report.md')
        (self.home / 'data/job/report.md').write_text('Kept evidence\n')
        (self.home / 'data/job/cache').mkdir()
        (self.home / 'data/job/cache/file').write_bytes(b'x' * 4096)
        self.old = int(time.time()) - 8 * 86400

    def task(self, *args):
        return subprocess.run(['tasks-axi', *args], cwd=self.home, env=self.env, check=True, capture_output=True, text=True).stdout

    def run_cli(self, *args, ok=True):
        p = subprocess.run(['bash', str(Path(os.environ['ROOT']) / 'bin/fm-task-retention.sh'), *args], cwd=self.home, env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout)
        return p

    def ready(self):
        self.run_cli('declare', 'job', '--scratch', 'cache')
        self.run_cli('complete', 'job', '--artifact', 'report.md')
        receipt = self.home / 'data/job/retention-complete.json'
        value = json.loads(receipt.read_text())
        value['completed_at'] = self.old
        receipt.write_text(json.dumps(value))

    def report(self, *args):
        output = self.run_cli('report', '--json', *args).stdout
        return next(row for row in json.loads(output)['tasks'] if row['task'] == 'job')

    def test_missing_config_uses_report_default_and_start_still_invalidates(self):
        self.ready()
        (self.home / 'config').rmdir()
        self.assertEqual(self.report('--prune')['eligible_bytes'], 4096)
        self.assertTrue((self.home / 'data/job/cache/file').exists())
        self.run_cli('start', 'job')
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertFalse((self.home / 'config').exists())

    def test_relative_roots_resolve_from_home(self):
        self.ready()
        self.env.update(FM_HOME='.', FM_DATA_OVERRIDE='data',
                        FM_STATE_OVERRIDE='state', FM_CONFIG_OVERRIDE='config')
        self.assertEqual(self.report()['eligible_bytes'], 4096)

    def test_empty_overrides_use_home_defaults(self):
        for name in ('DATA', 'STATE', 'CONFIG', 'ROOT'):
            self.env['FM_' + name + '_OVERRIDE'] = ''
        self.assertEqual(self.report()['eligible_bytes'], 0)

    def test_backlog_preserves_punctuation_and_multiline_holds(self):
        self.ready()
        title = 'Review "quoted", comma and (truncated marker'
        self.task('add', 'decision', title)
        self.task('update', 'decision', '--body',
                  'Review "evidence", details\n' + 'long notes ' * 100 + '\ndata/job/cache/file (truncated')
        self.task('hold', 'decision', '--kind', 'captain', '--reason', 'Review evidence')
        self.assertIn('hold', self.report()['reason'])
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_failed_tick_backs_off_after_queue_is_drained(self):
        (self.home / 'config/task-retention').write_text('invalid\n')
        self.run_cli('tick', ok=False)
        queue = self.home / 'state/.wake-queue'
        self.assertIn('task-retention report failed', queue.read_text())
        queue.write_text('')
        self.run_cli('tick')
        self.assertEqual(queue.read_text(), '')
        # A fresh process also respects the durable retry delay.
        self.run_cli('tick')
        self.assertEqual(queue.read_text(), '')
        attempt = self.home / 'state/.task-retention-attempt'
        os.utime(attempt, (self.old, self.old))
        self.run_cli('tick', ok=False)
        self.assertIn('task-retention report failed', queue.read_text())
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_missing_candidate_is_reported_without_deletion(self):
        self.ready()
        self.task('rm', 'job')
        row = self.report('--prune')
        self.assertEqual(row['eligible_bytes'], 0)
        self.assertIn('unavailable in backlog', row['reason'])
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_incomplete_hold_reads_block_all_deletion(self):
        self.ready()
        (self.home / 'config/task-retention').write_text('prune\n')
        self.task('add', 'decision', 'A "quoted", hold')
        self.task('hold', 'decision', '--kind', 'captain', '--reason', 'Review')
        fakebin = self.home / 'fakebin'
        fakebin.mkdir()
        tool = fakebin / 'tasks-axi'
        real = shutil.which('tasks-axi', path=self.env['PATH'])
        original_path = self.env['PATH']
        self.env['PATH'] = str(fakebin) + os.pathsep + original_path
        for mode in ('failed', 'count', 'truncated'):
            with self.subTest(mode=mode):
                tool.write_text('#!' + sys.executable + '\n'
                    'import os, sys\n'
                    'args = sys.argv[1:]\n'
                    'mode = ' + repr(mode) + '\n'
                    'if mode == "count" and args[0] == "list":\n'
                    '    print("count: 201 of 300 total"); sys.exit(0)\n'
                    'if args[:2] == ["show", "decision"]:\n'
                    '    if mode == "failed": sys.exit(1)\n'
                    '    if mode == "truncated":\n'
                    '        print(' + repr('task:\n  id: decision\n  state: queued\n  closed: -\n  hold_kind: captain\n  hold_reason: Review\n  links: none\n  body: "notes\\n... (truncated, 900 chars total - use show decision --full to see complete text)"') + '); sys.exit(0)\n'
                    'os.execv(' + repr(real) + ', [' + repr(real) + '] + args)\n')
                tool.chmod(0o755)
                row = self.report('--prune')
                self.assertEqual(row['eligible_bytes'], 0)
                self.assertIn('captain hold scan incomplete', row['reason'])
                self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_undeclared_kept(self):
        self.assertEqual(self.report()['eligible_bytes'], 0)
        self.assertIn('undeclared', self.report()['reason'])

    def test_report_only_and_enabled(self):
        self.ready()
        self.assertEqual(self.report()['eligible_bytes'], 4096)
        self.report('--prune')
        self.assertTrue((self.home / 'data/job/cache/file').exists())
        (self.home / 'config/task-retention').write_text('prune\n')
        self.report('--prune', '--dry-run')
        self.assertTrue((self.home / 'data/job/cache/file').exists())
        self.report('--prune')
        self.assertFalse((self.home / 'data/job/cache/file').exists())
        self.assertTrue((self.home / 'data/job/report.md').exists())
        log = (self.home / 'data/job/retention-removals.jsonl').read_text()
        self.assertIn('cache/file', log)
        self.assertIn('"removed"', log)

    def test_completion_grace_and_active(self):
        self.run_cli('declare', 'job', '--scratch', 'cache')
        self.assertEqual(self.report()['eligible_bytes'], 0)
        self.run_cli('complete', 'job', '--artifact', 'report.md')
        self.assertIn('grace', self.report()['reason'])
        self.ready_from_existing()
        (self.home / 'state/job.meta').write_text('window=job\n')
        self.assertIn('endpoint', self.report()['reason'])
        (self.home / 'state/job.meta').unlink()
        self.task('reopen', 'job')
        self.assertIn('Done', self.report()['reason'])

    def ready_from_existing(self):
        path = self.home / 'data/job/retention-complete.json'
        value = json.loads(path.read_text())
        value['completed_at'] = self.old
        path.write_text(json.dumps(value))

    def test_other_open_hold_references_task(self):
        self.ready()
        self.task('add', 'decision', 'Review evidence')
        self.task('hold', 'decision', '--kind', 'captain', '--reason', 'Review data/job/cache/file')
        self.assertIn('hold', self.report()['reason'])

    def test_title_only_hold_reference_blocks_pruning(self):
        self.ready()
        self.task('add', 'decision', 'Review job evidence')
        self.task('hold', 'decision', '--kind', 'captain', '--reason', 'Awaiting approval')
        (self.home / 'config/task-retention').write_text('prune\n')
        row = self.report('--prune')
        self.assertEqual(row['eligible_bytes'], 0)
        self.assertIn('open captain hold references task: decision', row['reason'])
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_declaration_change_after_completion_is_ineligible(self):
        self.ready()
        path = self.home / 'data/job/scratch.json'
        value = json.loads(path.read_text())
        value['scratch'].append('extra')
        path.write_text(json.dumps(value))
        self.assertEqual(self.report()['eligible_bytes'], 0)

    def test_unsafe_declaration_and_symlink(self):
        self.run_cli('declare', 'job', '--scratch', '../escape', ok=False)
        self.ready()
        (self.home / 'data/job/cache/link').symlink_to(self.home / 'user', target_is_directory=True)
        self.assertIn('symlink', self.report()['reason'])

    def test_evidence_and_control_files_protected(self):
        self.run_cli('declare', 'job', '--scratch', '*')
        self.run_cli('complete', 'job', '--artifact', 'report.md')
        self.ready_from_existing()
        self.assertEqual(self.report()['eligible_bytes'], 4096)

    def test_worktree_report_only(self):
        self.run_cli('declare', 'job', '--scratch', 'cache', '--worktree-cache', 'node_modules')
        worktree = self.home / 'slot/repo'
        worktree.mkdir(parents=True)
        (worktree / 'node_modules').mkdir()
        (worktree / 'node_modules/x').write_bytes(b'x' * 128)
        self.run_cli('complete', 'job', '--artifact', 'report.md', '--worktree', str(worktree), '--lease-released')
        row = self.report()
        self.assertEqual(row['worktree']['reason'], 'released worktree remains; report only')
        self.assertEqual(row['worktree']['cache_bytes'], 128)
        self.assertTrue(worktree.exists())

    def shell(self, script, *args, ok=True):
        result = subprocess.run(['bash', '-eu', '-c', script, '_', os.environ['ROOT'],
                                 str(self.home), *args], cwd=self.home, env=self.env,
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def local_fixture(self):
        self.shell(''' . "$1/tests/fixtures.sh"
            fm_git_worktree "$2/project" "$2/worker" fm/job
            printf 'landed change\\n' > "$2/worker/landed.txt"
            git -C "$2/worker" add landed.txt
            git -C "$2/worker" -c user.name=Tests -c user.email=tests@example.invalid commit -qm change
            fm_test_spawn_home "$2" codex
            fakebin=$(fm_test_make_spawn_fakebin "$2/tools" gh gh-axi no-mistakes)
            mkdir -p "$2/bin"
            printf '#!/bin/sh\nexit 0\n' > "$2/bin/fm-guard.sh"
            chmod +x "$2/bin/fm-guard.sh"
        ''')
        self.env['PATH'] = str(self.home / 'tools/fakebin') + os.pathsep + self.env['PATH']
        self.env['FM_ROOT_OVERRIDE'] = str(self.home)
        head = subprocess.check_output(['git', '-C', str(self.home / 'worker'), 'rev-parse', 'HEAD'], text=True).strip()
        (self.home / 'state/job.meta').write_text(
            'kind=ship\nmode=local-only\nbranch=fm/job\nspawn_gen=fixture-1\n'
            'window=firstmate:fm-job\nendpoint_task_id=job\nproject=%s\nworktree=%s\nlocal_done_head=%s\n' %
            (self.home / 'project', self.home / 'absent-worker', head))
        return head

    def teardown(self, ok=True):
        result = subprocess.run(['bash', str(Path(os.environ['ROOT']) / 'bin/fm-teardown.sh'), 'job'],
                                cwd=self.home, env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.home / 'state/job.meta').exists())
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((self.home / 'state/job.meta').exists())
        return result

    def test_local_landing_teardown_requires_proof(self):
        self.local_fixture()
        self.run_cli('declare', 'job', '--scratch', '*')
        self.task('reopen', 'job')
        self.task('start', 'job')
        result = subprocess.run(['bash', str(Path(os.environ['ROOT']) / 'bin/fm-merge-local.sh'), 'job'],
                                cwd=self.home, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        proof = self.home / 'data/job/retention-local.json'
        self.assertTrue(proof.exists())
        original = proof.read_bytes()
        identity = proof.stat()
        retry = subprocess.run(['bash', str(Path(os.environ['ROOT']) / 'bin/fm-merge-local.sh'), 'job'],
                               cwd=self.home, env=self.env, capture_output=True, text=True)
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(proof.read_bytes(), original)
        self.assertEqual(proof.stat().st_ino, identity.st_ino)
        self.assertEqual(proof.stat().st_mtime_ns, identity.st_mtime_ns)
        prior = subprocess.check_output(['git', '-C', str(self.home / 'project'),
                                         'rev-parse', 'HEAD^'], text=True).strip()
        conflict = self.run_cli('confirm-local', 'job', '--project', str(self.home / 'project'),
                                '--branch', 'main', '--head', prior, ok=False)
        self.assertIn('conflicting local landing receipt', conflict.stderr)
        self.assertEqual(proof.read_bytes(), original)
        self.teardown()
        self.assertIn('grace', self.report()['reason'])
        self.ready_from_existing()
        row = self.report()
        self.assertEqual(row['eligible_bytes'], 4096)
        self.assertTrue(proof.exists())

    def external_pr_fixture(self, state='MERGED', pushed=False):
        head = self.local_fixture()
        url = 'https://github.com/example/repo/pull/7'
        meta = self.home / 'state/job.meta'
        value = meta.read_text().replace('mode=local-only', 'mode=no-mistakes')
        value = value.replace(str(self.home / 'absent-worker'), str(self.home / 'worker'))
        meta.write_text(value + 'pr=' + url + '\n')
        gh = self.home / 'tools/fakebin/gh'
        gh.write_text('#!/usr/bin/env bash\n'
                      'if [ "${1:-} ${2:-}" = "pr view" ]; then\n'
                      "  printf '%s\\t%%s\\t%%s\\n' '%s' '%s'\n" % (state, head, url) +
                      '  exit 0\nfi\nexit 1\n')
        gh.chmod(0o755)
        self.run_cli('declare', 'job', '--scratch', 'cache')
        self.task('reopen', 'job')
        self.task('start', 'job')
        self.assertFalse((self.home / 'data/job/retention-merge.json').exists())
        if pushed:
            subprocess.run(['git', '-C', str(self.home / 'worker'), 'push', '-q',
                            'origin', 'HEAD:refs/heads/fm/job'], env=self.env,
                           check=True, capture_output=True, text=True)
            remaining = subprocess.check_output(['git', '-C', str(self.home / 'worker'),
                                                  'log', '--format=%H', 'HEAD', '--not', '--remotes', '--'],
                                                 env=self.env, text=True)
            self.assertEqual(remaining, '')
        return url

    def assert_teardown_records_merge(self, url):
        self.teardown()
        proof = json.loads((self.home / 'data/job/retention-merge.json').read_text())
        receipt = json.loads((self.home / 'data/job/retention-complete.json').read_text())
        self.assertEqual(proof['url'], url)
        self.assertEqual(receipt['merged_pr'], url)
        self.assertIn('grace', self.report()['reason'])
        self.ready_from_existing()
        self.assertEqual(self.report()['eligible_bytes'], 4096)

    def test_teardown_preserves_externally_merged_pr_before_poll(self):
        self.assert_teardown_records_merge(self.external_pr_fixture())

    def test_external_merge_teardown_with_relative_home_and_missing_config(self):
        self.external_pr_fixture()
        shutil.rmtree(self.home / 'config')
        self.env['FM_HOME'] = '.'
        self.env['FM_ROOT_OVERRIDE'] = '.'
        for name in ('DATA', 'STATE', 'CONFIG'):
            self.env['FM_' + name + '_OVERRIDE'] = ''
        self.teardown()
        receipt = json.loads((self.home / 'data/job/retention-complete.json').read_text())
        self.assertTrue(receipt['merged_pr'])

    def test_pushed_external_merge_records_completion(self):
        self.assert_teardown_records_merge(self.external_pr_fixture(pushed=True))

    def test_pushed_unmerged_branch_remains_ineligible(self):
        self.external_pr_fixture(state='OPEN', pushed=True)
        self.teardown()
        self.assertFalse((self.home / 'data/job/retention-merge.json').exists())
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertEqual(self.report()['eligible_bytes'], 0)
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_local_teardown_without_landing_proof_stays_ineligible(self):
        self.local_fixture()
        self.run_cli('declare', 'job', '--scratch', 'cache')
        self.task('reopen', 'job')
        self.task('start', 'job')
        self.teardown()
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertEqual(self.report()['eligible_bytes'], 0)

    def spawn_fixture(self, ok=True, missing_config=False):
        return self.shell(''' . "$1/tests/fixtures.sh"
            fm_git_worktree "$2/project" "$2/pool" fm/job
            fm_test_spawn_home "$2" codex
            fakebin=$(fm_test_make_spawn_fakebin "$2/tools" gh gh-axi)
            fm_test_spawn_brief "$2" job
            printf '\\n# Definition of done\\nDelivery contract: mode=local-only\\n' >> "$2/data/job/brief.md"
            if [ "$3" = missing ]; then
                rm "$2/config/crew-harness"
                rmdir "$2/config"
            fi
            fm_test_run_spawn "$2" "$2/pool" "$fakebin" job "$2/project" --mode local-only --yolo off --harness codex
        ''', 'missing' if missing_config else 'configured', ok=ok)

    def test_launch_refuses_when_retention_invalidation_fails(self):
        self.ready()
        receipt = self.home / 'data/job/retention-complete.json'
        receipt.unlink()
        receipt.mkdir()
        self.task('reopen', 'job')
        self.spawn_fixture(ok=False)
        self.assertTrue(receipt.is_dir())
        self.assertFalse((self.home / 'state/job.meta').exists())

    def test_launch_without_config_invalidates_receipts(self):
        self.ready()
        self.task('reopen', 'job')
        self.spawn_fixture(missing_config=True)
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertTrue((self.home / 'state/job.meta').exists())

    def test_teardown_refuses_when_retention_merge_write_fails(self):
        self.external_pr_fixture()
        (self.home / 'data/job/retention-merge.json').mkdir()
        result = self.teardown(ok=False)
        self.assertIn('refusing teardown', result.stderr)
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_reused_task_spawn_invalidates_completion_and_refreshes_grace(self):
        self.ready()
        self.task('reopen', 'job')
        self.spawn_fixture()
        self.assertFalse((self.home / 'data/job/retention-complete.json').exists())
        self.assertEqual(self.report()['eligible_bytes'], 0)
        (self.home / 'state/job.meta').unlink()
        self.task('done', 'job', '--report', 'data/job/report.md')
        self.run_cli('complete', 'job', '--artifact', 'report.md')
        self.assertIn('grace', self.report()['reason'])
        self.ready_from_existing()
        self.run_cli('complete', 'job', '--artifact', 'report.md')
        self.assertIn('grace', self.report()['reason'])
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_archived_task_remains_eligible_and_reports_worktree(self):
        self.run_cli('declare', 'job', '--scratch', 'cache', '--worktree-cache', 'node_modules')
        worktree = self.home / 'slot/repo'
        (worktree / 'node_modules').mkdir(parents=True)
        (worktree / 'node_modules/x').write_bytes(b'x' * 128)
        self.run_cli('complete', 'job', '--artifact', 'report.md', '--worktree', str(worktree), '--lease-released')
        self.ready_from_existing()
        config = self.home / '.tasks.toml'
        config.write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n'
                          'archive = "data/done-archive.md"\ndone_keep = 1\n')
        self.task('add', 'later', 'Later completion')
        self.task('done', 'later')
        self.assertNotIn('job', self.run_cli('backlog').stdout)
        self.run_cli('archived', 'job')
        row = self.report()
        self.assertEqual(row['eligible_bytes'], 4096)
        self.assertEqual(row['worktree']['cache_bytes'], 128)
        fakebin = self.home / 'read-failure-bin'
        fakebin.mkdir()
        real = shutil.which('tasks-axi', path=self.env['PATH'])
        tool = fakebin / 'tasks-axi'
        tool.write_text('#!' + sys.executable + '\nimport os, sys\n'
                        'if sys.argv[1:3] == ["show", "job"]: sys.exit(1)\n'
                        'os.execv(%r, [%r] + sys.argv[1:])\n' % (real, real))
        tool.chmod(0o755)
        original_path = self.env['PATH']
        self.env['PATH'] = str(fakebin) + os.pathsep + original_path
        (self.home / 'config/task-retention').write_text('prune\n')
        self.assertEqual(self.report('--prune')['eligible_bytes'], 0)
        self.assertTrue((self.home / 'data/job/cache/file').exists())
        self.env['PATH'] = original_path
        self.report('--prune')
        self.assertFalse((self.home / 'data/job/cache/file').exists())
        self.assertTrue((worktree / 'node_modules/x').exists())

    def test_brief_creates_explicit_declaration(self):
        subprocess.run(['bash', str(Path(os.environ['ROOT']) / 'bin/fm-brief.sh'),
                        'new-job', 'example', '--mode', 'direct-PR', '--scratch', 'renders/**',
                        '--worktree-cache', 'node_modules'], cwd=self.home, env=self.env,
                       check=True, capture_output=True, text=True)
        value = json.loads((self.home / 'data/new-job/scratch.json').read_text())
        self.assertEqual(value['scratch'], ['renders/**'])
        self.assertEqual(value['worktree_cache'], ['node_modules'])

    def test_confirmed_merge_owner_preserves_evidence(self):
        self.run_cli('declare', 'job', '--scratch', 'cache')
        url = 'https://github.com/example/repo/pull/1'
        subprocess.run(['bash', '-c', '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" job "$2" self',
                        '_', os.environ['ROOT'], url], cwd=self.home, env=self.env,
                       check=True, capture_output=True, text=True)
        path = self.home / 'data/job/retention-merge.json'
        proof = json.loads(path.read_text())
        self.assertEqual(proof['url'], url)
        original = path.stat()
        subprocess.run(['bash', '-c', '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" job "$2" self',
                        '_', os.environ['ROOT'], url], cwd=self.home, env=self.env,
                       check=True, capture_output=True, text=True)
        self.assertEqual(path.stat().st_ino, original.st_ino)
        self.assertEqual(path.stat().st_mtime_ns, original.st_mtime_ns)
        latest = 'https://github.com/example/repo/pull/2'
        subprocess.run(['bash', '-c', '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" job "$2" self',
                        '_', os.environ['ROOT'], latest], cwd=self.home, env=self.env,
                       check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(path.read_text())['url'], latest)
        self.task('done', 'job', '--pr', latest)
        self.assertNotIn(url, self.run_cli('backlog').stdout)
        self.run_cli('complete', 'job')
        self.ready_from_existing()
        self.assertEqual(self.report()['eligible_bytes'], 4096)
        (self.home / 'data/job/retention-merge.json').unlink()
        self.assertEqual(self.report()['eligible_bytes'], 0)

    def test_weekly_report_and_dry_run(self):
        self.ready()
        self.run_cli('report', '--periodic', '--dry-run')
        destination = self.home / 'state/task-retention-report.json'
        self.assertFalse(destination.exists())
        self.run_cli('report', '--periodic')
        first = destination.read_bytes()
        self.assertEqual(self.run_cli('report', '--periodic').stdout, '')
        self.assertEqual(destination.read_bytes(), first)

    def test_tick_without_task_data_does_not_create_a_wake(self):
        self.env['FM_DATA_OVERRIDE'] = str(self.home / 'absent-data')
        self.run_cli('tick')
        self.assertFalse((self.home / 'state/.wake-queue').exists())

    def test_tick_publishes_one_weekly_wake(self):
        self.ready()
        self.run_cli('tick', '--dry-run')
        queue = self.home / 'state/.wake-queue'
        self.assertFalse(queue.exists())
        self.run_cli('tick')
        first = queue.read_bytes()
        self.assertIn(b'task-retention', first)
        self.run_cli('tick')
        self.assertEqual(queue.read_bytes(), first)

    def test_malformed_and_traversal_records_fail_closed(self):
        self.ready()
        path = self.home / 'data/job/scratch.json'
        value = json.loads(path.read_text())
        value['scratch'] = ['cache/../report.md']
        path.write_text(json.dumps(value))
        self.assertEqual(self.report()['eligible_bytes'], 0)
        path.write_text('{broken')
        self.assertEqual(self.report()['eligible_bytes'], 0)

    def test_completed_tasks_sharing_released_worktree_are_ambiguous(self):
        worktree = self.home / 'slot/repo'
        (worktree / 'node_modules').mkdir(parents=True)
        cache = worktree / 'node_modules/x'
        cache.write_bytes(b'x' * 128)
        self.assertFalse((worktree.parent / '.fm-slot-owner').exists())
        self.run_cli('declare', 'job', '--scratch', 'cache', '--worktree-cache', 'node_modules')
        self.run_cli('complete', 'job', '--artifact', 'report.md',
                     '--worktree', str(worktree), '--lease-released')
        self.ready_from_existing()
        other = self.home / 'data/other'
        other.mkdir()
        (other / 'report.md').write_text('Other task evidence\n')
        self.task('add', 'other', 'Later slot occupant')
        self.task('done', 'other', '--report', 'data/other/report.md')
        self.run_cli('declare', 'other', '--worktree-cache', 'node_modules')
        self.run_cli('complete', 'other', '--artifact', 'report.md',
                     '--worktree', str(worktree), '--lease-released')
        for args in ((), ('--prune',)):
            if args:
                (self.home / 'config/task-retention').write_text('prune\n')
            output = json.loads(self.run_cli('report', '--json', *args).stdout)
            self.assertEqual(len(output['shared_worktrees']), 1)
            shared = output['shared_worktrees'][0]
            self.assertEqual(shared['path'], str(worktree))
            self.assertEqual(shared['tasks'], ['job', 'other'])
            self.assertIn('ambiguous', shared['reason'])
            self.assertEqual(shared['bytes'], 128)
            self.assertEqual(shared['cache_bytes'], 0)
            for row in output['tasks']:
                self.assertIsNone(row['worktree'])
                self.assertIn('ambiguous', row['worktree_reason'])
            self.assertEqual(cache.read_bytes(), b'x' * 128)
        text = self.run_cli('report').stdout
        self.assertEqual(text.count(str(worktree)), 1)

    def test_reassigned_worktree_not_attributed(self):
        self.ready()
        worktree = self.home / 'slot/repo'
        worktree.mkdir(parents=True)
        (worktree.parent / '.fm-slot-owner').write_text('task=another\n')
        path = self.home / 'data/job/retention-complete.json'
        value = json.loads(path.read_text())
        value.update(worktree=str(worktree), lease_released=True)
        path.write_text(json.dumps(value))
        self.assertIn('uncertain', self.report()['worktree']['reason'])

    def test_unreadable_backlog_refuses_every_prune(self):
        self.ready()
        (self.home / 'config/task-retention').write_text('prune\n')
        (self.home / '.tasks.toml').write_text('backend = [invalid\n')
        row = self.report('--prune')
        self.assertEqual(row['eligible_bytes'], 0)
        self.assertIn('backlog', row['reason'])
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_data_root_symlink_ancestor_is_refused(self):
        self.ready()
        (self.home / 'alias').symlink_to(self.home, target_is_directory=True)
        (self.home / 'config/task-retention').write_text('prune\n')
        self.env['FM_DATA_OVERRIDE'] = str(self.home / 'alias/data')
        self.run_cli('report', '--prune', ok=False)
        self.assertTrue((self.home / 'data/job/cache/file').exists())

    def test_task_symlink_and_hardlinked_audit_are_refused(self):
        self.ready()
        (self.home / 'data/foreign').symlink_to(self.home / 'user', target_is_directory=True)
        result = json.loads(self.run_cli('report', '--json').stdout)
        foreign = next(row for row in result['tasks'] if row['task'] == 'foreign')
        self.assertEqual(foreign['eligible_bytes'], 0)
        (self.home / 'config/task-retention').write_text('prune\n')
        os.link(self.home / 'data/job/report.md', self.home / 'data/job/retention-removals.jsonl')
        row = self.report('--prune')
        self.assertIn('audit', row['reason'])
        self.assertEqual((self.home / 'data/job/report.md').read_text(), 'Kept evidence\n')

    def test_engine_limit_does_not_constrain_real_backlog_children(self):
        self.ready()
        real_tasks = shutil.which('tasks-axi', path=self.env['PATH'])
        self.assertIsNotNone(real_tasks)
        fakebin = self.home / 'limit-probe-bin'
        fakebin.mkdir()
        child_log = self.home / 'child-limits.jsonl'
        audit_log = self.home / 'engine-limits.jsonl'
        wrapper = fakebin / 'tasks-axi'
        wrapper.write_text('#!' + sys.executable + '\nimport json, os, resource, sys\n'
                           'with open(%r, "a") as log:\n' % str(child_log) +
                           '    log.write(json.dumps(resource.getrlimit(resource.RLIMIT_AS)) + "\\n")\n'
                           'os.execv(%r, [%r] + sys.argv[1:])\n' % (real_tasks, real_tasks))
        wrapper.chmod(0o755)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env['PATH'])
        driver = """
import json, os, resource, runpy, sys
log_path, engine = sys.argv[1:]
def record(value):
    with open(log_path, 'a') as log:
        log.write(json.dumps(value) + '\\n')
record({'event': 'baseline', 'pid': os.getpid(), 'limits': resource.getrlimit(resource.RLIMIT_AS)})
def audit(event, args):
    if event == 'subprocess.Popen':
        record({'event': event, 'pid': os.getpid(), 'limits': resource.getrlimit(resource.RLIMIT_AS)})
    elif event == 'resource.setrlimit' and args[0] == resource.RLIMIT_AS:
        record({'event': event, 'pid': os.getpid(), 'attempt': args[1]})
sys.addaudithook(audit)
sys.argv = [engine, 'report', '--json']
sys.path.insert(0, os.path.dirname(engine))
runpy.run_path(engine, run_name='__main__')
"""
        result = subprocess.run([sys.executable, '-c', driver, str(audit_log),
                                 str(Path(os.environ['ROOT']) / 'bin/fm-task-retention.py')],
                                cwd=self.home, env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output['tasks'][0]['eligible_bytes'], 4096)
        events = [json.loads(line) for line in audit_log.read_text().splitlines()]
        baseline = events[0]
        parents = [event for event in events if event['pid'] == baseline['pid']]
        attempts = [event['attempt'] for event in parents if event['event'] == 'resource.setrlimit']
        self.assertTrue(attempts)
        self.assertEqual(attempts[0][1], baseline['limits'][1])
        launches = [event['limits'] for event in parents if event['event'] == 'subprocess.Popen']
        self.assertTrue(launches)
        enforced = all(0 < limits[0] <= 128 * 1048576 for limits in launches)
        if sys.platform.startswith('linux'):
            self.assertTrue(enforced, launches)
        print('retention engine address-space cap enforced: %s (%s)' % (enforced, sys.platform))
        if not sys.platform.startswith('linux'):
            print('Linux address-space enforcement proof unavailable on this host')
        children = [json.loads(line) for line in child_log.read_text().splitlines()]
        self.assertTrue(children)
        self.assertTrue(all(limits == baseline['limits'] for limits in children), children)

    def test_streaming_scan_budget(self):
        self.ready()
        for i in range(5000):
            (self.home / ('data/job/cache/item-%05d' % i)).write_bytes(b'x')
        start = time.monotonic()
        output = json.loads(self.run_cli('report', '--json').stdout)
        elapsed = time.monotonic() - start
        row = next(row for row in output['tasks'] if row['task'] == 'job')
        self.assertEqual(row['eligible_bytes'], 9096)
        self.assertLess(output['visited_entries'], 200000)
        self.assertLess(elapsed, 120)
        print('retention benchmark: 5,000 scratch files, %.3fs, %d visited entries' %
              (elapsed, output['visited_entries']))


unittest.main()
PY
