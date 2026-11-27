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
        self.env = dict(os.environ, HOME=str(self.home / 'user'), FM_HOME=str(self.home))
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
        proof = json.loads((self.home / 'data/job/retention-merge.json').read_text())
        self.assertEqual(proof['url'], url)
        self.task('done', 'job', '--pr', url)
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
