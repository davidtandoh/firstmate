#!/usr/bin/env bash
# Collector contract: window boundaries, deterministic output, missing telemetry,
# bounded reads, unsafe paths, optional forge enrichment, and dry-run isolation.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop())
NOW = 1792440000


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'state').mkdir()
        (self.home / 'data').mkdir()
        self.env = dict(os.environ, HOME=str(self.home), FM_HOME=str(self.home))
        for name in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
            self.env.pop(name, None)

    def run_collector(self, *args, ok=True):
        result = subprocess.run(
            ['bash', str(ROOT / 'bin/fm-velocity-facts.sh'), '--now', str(NOW),
             '--json', *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        return json.loads(result.stdout) if ok else result

    def test_empty_and_dry_run(self):
        preview = self.run_collector('--dry-run')
        self.assertFalse(Path(preview['path']).exists())
        result = self.run_collector()
        facts = json.loads(Path(result['path']).read_text())
        self.assertEqual(facts['tasks'], [])
        self.assertIsNone(facts['notifications']['count_24h'])
        self.assertTrue(facts['limitations'])
        self.assertEqual(self.run_collector(ok=False).returncode, 1)
        before = Path(result['path']).read_bytes()
        self.assertTrue(self.run_collector('--reuse')['reused'])
        self.assertEqual(Path(result['path']).read_bytes(), before)

    def test_window_and_pr_enrichment(self):
        (self.home / 'state/task.status').write_text(
            'working [at={}]: before\nblocked [at={}]: start\n'
            'resolved [at={}]: end\ndone [at={}]: future\n'.format(
                NOW - 86401, NOW - 86400, NOW - 1, NOW))
        (self.home / 'state/task.meta').write_text(
            'kind=ship\nspawn_gen=s{}.123.456\n'
            'pr=https://github.com/example/project/pull/7\n'.format(NOW - 90000))
        (self.home / 'state/.wake-queue').write_text(
            '{}\t1\tsignal\ttask\tblocked\n{}\t2\tcheck\tpr\tready\n'.format(
                NOW - 1, NOW))
        fake = self.home / 'fakebin'
        fake.mkdir()
        tool = fake / 'gh-axi'
        tool.write_text('#!/bin/sh\nprintf \'created_at: "2026-10-18T10:00:00Z"\\nmerged_at: null\\n\'\n')
        tool.chmod(0o755)
        self.env['PATH'] = str(fake) + os.pathsep + self.env['PATH']
        result = self.run_collector('--include-prs')
        facts = json.loads(Path(result['path']).read_text())
        task = facts['tasks'][0]
        self.assertEqual([e['verb'] for e in task['events']], ['blocked', 'resolved'])
        self.assertEqual(task['preceding_event']['verb'], 'working')
        self.assertEqual(facts['wakes']['pending_by_type'], {'signal': 1})
        self.assertEqual(facts['prs'][0]['created_at'], '2026-10-18T10:00:00Z')
        self.assertIsNone(facts['prs'][0]['merged_at'])
        self.assertEqual(facts['prs'][0]['source'], 'gh-axi')

    def test_bounds_and_legacy(self):
        (self.home / 'state/task.status').write_text(
            'x' * 300000 + '\nworking: legacy\nworking [at={}]: now\n'.format(NOW - 1))
        result = self.run_collector()
        path = Path(result['path'])
        facts = json.loads(path.read_text())
        self.assertTrue(any('tail' in s for s in facts['limitations']))
        self.assertEqual(facts['untimed_status_lines'], 1)
        self.assertEqual(len(facts['tasks'][0]['events']), 1)
        self.assertLess(path.stat().st_size, 2097152)

    def test_carried_wait_and_secondary_telemetry(self):
        (self.home / 'state/task.meta').write_text('kind=scout\n')
        (self.home / 'state/task.status').write_text('paused [at={}]: long wait\n'.format(NOW - 90000))
        (self.home / 'state/ready.meta').write_text('kind=ship\n')
        (self.home / 'state/ready.status').write_text('done [at={}]: ready for review\n'.format(NOW - 90000))
        (self.home / 'state/.watch-triage.log').write_text(
            '[2026-10-19T12:00:00+0000] absorbed push: task\n')
        (self.home / 'state/.watch-deliveries.log').write_text('123\tidentity\tsignal: task\n')
        (self.home / 'data/backlog.md').write_text(
            '## In flight\n- [ ] task - Audit (since 2026-10-19)\n')
        result = self.run_collector()
        facts = json.loads(Path(result['path']).read_text())
        tasks = {task['id']: task for task in facts['tasks']}
        self.assertEqual(tasks['task']['preceding_event']['verb'], 'paused')
        self.assertEqual(tasks['ready']['preceding_event']['verb'], 'done')
        self.assertEqual(facts['notifications']['retained_by_type'], {'signal': 1})
        self.assertEqual(facts['triage_by_type'], {'absorbed push': 1})
        self.assertEqual(facts['backlog_dated_rows'][0]['section'], 'In flight')
        Path(result['path']).write_text('{"schema":"broken"}\n')
        self.run_collector('--reuse', ok=False)

    def test_symlinks_and_invalid_stamp(self):
        status = self.home / 'state/task.status'
        status.symlink_to('/etc/passwd')
        self.run_collector(ok=False)
        status.unlink()
        status.write_text('working [at=broken]: invalid\n')
        self.run_collector(ok=False)
        status.unlink()
        (self.home / 'data/velocity-audit').symlink_to(self.home / 'state')
        self.run_collector(ok=False)

    def test_nightly_idempotent_queue_and_preview(self):
        command = ['bash', str(ROOT / 'bin/fm-velocity-nightly.sh'), '--json']
        preview = subprocess.run(command + ['--dry-run'], env=self.env, text=True,
                                 capture_output=True, check=True)
        self.assertTrue(json.loads(preview.stdout)['dry_run'])
        self.assertEqual(list((self.home / 'data').iterdir()), [])
        self.assertEqual(list((self.home / 'state').iterdir()), [])
        first = subprocess.run(command, env=self.env, text=True, capture_output=True, check=True)
        second = subprocess.run(command, env=self.env, text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(first.stdout)['id'], json.loads(second.stdout)['id'])
        self.assertEqual(json.loads(second.stdout)['outcome'], 'replay')
        notes = list((self.home / 'state/inbox').glob('*.note'))
        self.assertEqual(len(notes), 1)
        self.assertIn('fm-spawn.sh --scout', notes[0].read_text())
        self.assertIn('Never apply proposals', notes[0].read_text())
        self.assertEqual(len(list((self.home / 'data/velocity-audit').glob('*/facts.json'))), 1)

    def test_nightly_help_without_home(self):
        env = dict(self.env)
        env.pop('FM_HOME', None)
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-velocity-nightly.sh'), '--help'],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Usage:', result.stdout)


unittest.main()
PY
