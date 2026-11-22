#!/usr/bin/env python3
"""Path policy and real git-range regressions; no network or third-party modules."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import ci_paths as ci


class Paths(unittest.TestCase):
    def enabled(self, *paths):
        return {key for key, value in ci.classify(paths).items() if value}

    def test_prose_and_manifests(self):
        for path in ('README.md', 'docs/guide.md', '.planning/STATE.md',
                     'plugins/api-design/skills/api-design/SKILL.md',
                     'plugins/api-design/skills/api-design/references/rest.md',
                     'plugins/shipyard/README.md', '.claude-plugin/marketplace.json',
                     'plugins/council/.codex-plugin/plugin.json'):
            with self.subTest(path=path):
                self.assertEqual(self.enabled(path), set())

    def test_operational_markdown_is_not_prose(self):
        for plugin in ('ship', 'shipyard', 'council'):
            for suffix in ('SKILL.md', 'references/protocol.md', 'scripts/up.sh', 'tests/t1.sh'):
                with self.subTest(plugin=plugin, suffix=suffix):
                    selected = self.enabled(f'plugins/{plugin}/skills/{plugin}/{suffix}')
                    self.assertIn('adapters', selected)
                    self.assertIn('floor', selected)
                    self.assertNotIn('check_test', selected)
                    self.assertIn('council' if plugin == 'ship' else plugin, selected)
                    self.assertNotIn('driver', selected)

    def test_shared_runs_dependants_not_gate_probes(self):
        for path in ('shared/flow/flow.sh', 'shared/policy/tests/t-policy.sh', 'shared/driver/targets.txt'):
            self.assertEqual(self.enabled(path), set(ci.SUITES) | {'floor'})

    def test_unknown_and_ci_fail_closed(self):
        for path in ('Makefile', '.github/workflows/ci.yml', 'scripts/check.sh',
                     'scripts/test_ci_paths.py', 'scripts/fixtures/probe.txt',
                     'plugins/new/skills/new/SKILL.md', 'plugins/api-design/tool.py',
                     'docs/tool.sh', 'new-executable', '.agents/skills/new'):
            self.assertEqual(self.enabled(path), set(ci.full()))
        self.assertEqual(self.enabled(), set(ci.full()))

    def test_union_and_unusual_filename(self):
        self.assertEqual(self.enabled('README.md', 'shared/flow/flow.sh'), set(ci.SUITES) | {'floor'})
        self.assertEqual(self.enabled('unknown\nREADME.md'), set(ci.full()))

    def test_missing_or_malformed_event_fails_closed(self):
        for event in ({}, {'before': '0' * 40, 'after': 'a' * 40}, None):
            with tempfile.TemporaryDirectory() as directory:
                event_path = Path(directory) / 'event.json'
                event_path.write_text(json.dumps(event))
                output = io.StringIO()
                with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event_path),
                                             'GITHUB_EVENT_NAME': 'push', 'GITHUB_OUTPUT': ''}), \
                        contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                    ci.main()
                self.assertTrue(all(line.endswith('=true') for line in output.getvalue().splitlines()))
                self.assertEqual(len(output.getvalue().splitlines()), len(ci.full()))


class Ranges(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(os.chdir, self.previous)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test Author')
        self.git('config', 'user.email', 'test' + chr(64) + 'example.invalid')
        self.write('README.md')
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(('git', *args), stderr=subprocess.PIPE).decode().strip()

    def write(self, path):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('example\n')

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'test: range fixture')
        return self.git('rev-parse', 'HEAD')

    def test_full_pr_diff_and_diverged_base(self):
        self.git('checkout', '-qb', 'topic')
        self.write('shared/flow/flow.sh')
        self.commit()
        self.write('docs/last.md')
        head = self.commit()
        self.git('checkout', '-q', self.base)
        self.write('base-only.txt')
        advanced_base = self.commit()
        paths = ci.changed_paths('pull_request', {'pull_request': {
            'base': {'sha': advanced_base}, 'head': {'sha': head}}})
        self.assertEqual(set(paths), {'shared/flow/flow.sh', 'docs/last.md'})

    def test_push_rename_deletion_addition_and_nul_paths(self):
        self.write('plugins/council/skills/council/scripts/old.sh')
        self.write('docs/delete.md')
        before = self.commit()
        self.git('mv', 'plugins/council/skills/council/scripts/old.sh', 'docs/renamed.md')
        Path('docs/delete.md').unlink()
        self.write('docs/space and\nnewline.md')
        after = self.commit()
        paths = ci.changed_paths('push', {'before': before, 'after': after})
        self.assertEqual(set(paths), {'plugins/council/skills/council/scripts/old.sh',
                                     'docs/renamed.md', 'docs/delete.md', 'docs/space and\nnewline.md'})
        self.assertTrue(ci.classify(paths)['council'])

    def test_over_300_files_keeps_late_gate_change(self):
        for index in range(350):
            self.write(f'docs/{index:03d}.md')
        self.write('scripts/check.sh')
        head = self.commit()
        event = {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': head}}}
        paths = ci.changed_paths('pull_request', event)
        self.assertEqual(len(paths), 351)
        self.assertGreater(paths.index('scripts/check.sh'), 299)
        self.assertTrue(all(ci.classify(paths).values()))
        pushed = ci.changed_paths('push', {'before': self.base, 'after': head})
        self.assertEqual(pushed, paths)

    def test_missing_history_and_zero_endpoint(self):
        for before in ('0' * 40, '1' * 40, '--option'):
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                ci.changed_paths('push', {'before': before, 'after': self.base})
        with self.assertRaises(ValueError):
            ci.changed_paths('workflow_dispatch', {})


class WorkflowTriggers(unittest.TestCase):
    def test_both_workflows_start_before_path_selection(self):
        root = Path(__file__).resolve().parent.parent
        for name in ('ci.yml', 'check-test.yml'):
            text = (root / '.github/workflows' / name).read_text()
            triggers = text.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
            with self.subTest(workflow=name):
                self.assertIn('  pull_request:\n', triggers)
                self.assertNotIn('paths', triggers)
                self.assertNotIn('pull_request_target', triggers)
                self.assertIn('fetch-depth: 0', text)
                self.assertIn('python3 scripts/ci_paths.py', text)


if __name__ == '__main__':
    unittest.main()
