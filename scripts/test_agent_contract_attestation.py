"""Publication must refuse stale/partial evidence before any baseline mutation."""
import copy
import datetime
import unittest
import agent_contract_attestation as publication
import agent_contracts as core


class EligibilityTests(unittest.TestCase):
    def report(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        row = {'runtime': 'codex', 'installed_version': '0.153.2', 'executable': '/tools/codex',
               'executable_sha256': 'binary', 'route': {'provider': 'fixture'},
               'inventory': {'status': 'passed'}, 'live': {'status': 'passed'},
               'preflight': {'status': 'passed'},
               'lifecycle': {'status': 'not_applicable', 'reason': 'native_notifier_has_no_session_lifecycle'}}
        report = {'schema': 1, 'contract_revision': 2, 'mode': 'verify', 'source_stable': True,
                  'source_fingerprint': 'source', 'started_source_fingerprint': 'source',
                  'bridge_sha256': 'bridge', 'started_at': now.isoformat(), 'created_at': now.isoformat(),
                  'contract_passed': True, 'runtimes': [row]}
        return report, now

    def test_stale_changed_source_partial_duplicate_and_failed(self):
        report, now = self.report()
        publication.validate_eligibility(report, 'source', 'bridge', now)
        cases = [dict(report, mode='live'), dict(report, source_fingerprint='old'),
                 dict(report, contract_revision=1), dict(report, contract_passed=False),
                 dict(report, runtimes=[]), dict(report, runtimes=report['runtimes'] * 2),
                 dict(report, started_at=(now-datetime.timedelta(days=2)).isoformat()),
                 dict(report, created_at=(now+datetime.timedelta(hours=2)).isoformat())]
        failed = copy.deepcopy(report)
        failed['runtimes'][0]['preflight']['status'] = 'not_run'
        cases.append(failed)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(core.EvidenceError):
                publication.validate_eligibility(value, 'source', 'bridge', now)

    def test_binary_or_route_change(self):
        report, _ = self.report()
        row = report['runtimes'][0]
        current = {'codex': dict(row)}
        publication.validate_current(report, current, {'codex': {'provider': 'fixture'}})
        for changed in [dict(row, installed_version='0.154.0'), dict(row, executable='/other/codex'),
                        dict(row, executable_sha256='changed')]:
            with self.assertRaises(core.EvidenceError):
                publication.validate_current(report, {'codex': changed}, {'codex': {'provider': 'fixture'}})
        with self.assertRaises(core.EvidenceError):
            publication.validate_current(report, current, {'codex': {'provider': 'different'}})


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        from pathlib import Path
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.report = {'export_nonce': 'current', 'artifacts': {}, 'runtimes': [{
            'runtime': 'opencode', 'executable': '/tools/opencode', 'live': {
                'scope': 'headless', 'cwd': '/probe', 'exit_code': 0, 'response_expected': 'RESULT:11839',
                'required_events': [['session.idle', 'turn-ended']], 'events': [{
                    'native_event': 'session.idle', 'event': 'turn-ended', 'cwd': '/probe', 'session_id': 'session'}]}}]}
        self.put('export-input.json', [{'runtime': 'opencode', 'executable': '/tools/opencode', 'workspace': '/probe',
            'scenario': 'headless', 'prompt': 'Compute 10100 + 1739. Reply only RESULT: followed immediately by the decimal sum. Do not use tools.'}])
        self.put('export-output.json', {'schema': 1, 'nonce': 'current', 'launches': [
            {'runtime': 'opencode', 'executable': '/tools/opencode', 'cwd': '/probe', 'status': 'prepared'}]})
        self.put('export-test-summary.json', {'result': 'Passed', 'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0})
        self.put('opencode-headless-stdout.log', 'RESULT: 11839')
        self.put('opencode-headless-stderr.log', '')

    def put(self, name, value):
        path = self.root / name
        path.write_bytes(value.encode() if isinstance(value, str) else publication.encode(value))
        self.report['artifacts'][name] = core.file_hash(path)

    def test_complete_artifacts(self):
        publication.validate_artifacts(self.report, self.root)

    def test_changed_file_and_escaping_path(self):
        (self.root / 'opencode-headless-stdout.log').write_text('RESULT: 1')
        with self.assertRaises(core.EvidenceError):
            publication.validate_artifacts(self.report, self.root)
        with self.assertRaises(core.EvidenceError):
            publication.artifact(self.report, self.root, '../outside')

    def test_zero_tests_even_with_matching_manifest(self):
        self.put('export-test-summary.json', {'result': 'Passed', 'totalTestCount': 0, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 0})
        with self.assertRaises(core.EvidenceError):
            publication.validate_artifacts(self.report, self.root)

    def test_wrong_answer_even_with_matching_manifest(self):
        self.put('opencode-headless-stdout.log', 'RESULT: 2')
        with self.assertRaises(core.EvidenceError):
            publication.validate_artifacts(self.report, self.root)

    def test_stale_export_nonce_and_missing_events(self):
        self.report['export_nonce'] = 'other-run'
        with self.assertRaises(core.EvidenceError):
            publication.validate_artifacts(self.report, self.root)
        self.report['export_nonce'] = 'current'
        self.report['runtimes'][0]['live']['events'] = []
        with self.assertRaises(core.EvidenceError):
            publication.validate_artifacts(self.report, self.root)


class WriteTests(unittest.TestCase):
    def setUp(self):
        import tempfile, json
        from pathlib import Path
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.baseline = self.root / 'baseline.json'
        self.matrix = self.root / 'matrix.md'
        original = (core.ROOT / 'docs-ai/064-agent-completion-signals/agent-attestation-interactive.json').read_bytes()
        self.baseline.write_bytes(original)
        (self.root / 'agent-attestation-interactive.json').write_bytes(original)
        for row in json.loads(original)['runtimes']:
            (self.root / row['record']).write_text('Legacy evidence')
        self.matrix.write_text('Intro\n' + publication.versions.render_matrix_line(publication.versions.load_attestation(self.baseline)) + '\nFooter\n')
        self.report, _ = EligibilityTests().report()
        row = self.report['runtimes'][0]
        row['route'] = core.load_policy(core.ROOT / 'Config/agent-contracts.example.json')['codex']
        row['live']['required_events'] = [['agent-turn-complete', 'turn-ended']]

    def test_partial_publication_preserves_other_runtimes_and_history(self):
        import json
        old = json.loads(self.baseline.read_text())
        result = publication.write_publication(self.report, self.baseline, self.matrix)
        new = json.loads(self.baseline.read_text())
        self.assertEqual([r for r in old['runtimes'] if r['runtime'] != 'codex'],
                         [r for r in new['runtimes'] if r['runtime'] != 'codex'])
        self.assertEqual(json.loads((self.root / 'agent-attestation-interactive.json').read_text()), old)
        self.assertEqual(publication.versions.check_matrix(publication.versions.load_attestation(self.baseline), self.matrix.read_text()), [])
        self.assertEqual(result['scope'], 'headless-contract')
        first = self.baseline.read_bytes()
        publication.write_publication(self.report, self.baseline, self.matrix)
        self.assertEqual(self.baseline.read_bytes(), first)

    def test_missing_matrix_marker_writes_nothing(self):
        self.matrix.write_text('No generated line')
        before = self.baseline.read_bytes()
        with self.assertRaises(core.EvidenceError):
            publication.write_publication(self.report, self.baseline, self.matrix)
        self.assertEqual(self.baseline.read_bytes(), before)
        self.assertFalse((self.root / 'attestations').exists())

    def test_write_failure_rolls_back_baseline_and_receipt(self):
        from unittest.mock import patch
        before = (self.baseline.read_bytes(), self.matrix.read_bytes())
        original = publication.replace_file
        count = 0
        def fail_second(path, data):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError('Injected disk error')
            original(path, data)
        with patch.object(publication, 'replace_file', side_effect=fail_second), self.assertRaises(core.EvidenceError):
            publication.write_publication(self.report, self.baseline, self.matrix)
        self.assertEqual((self.baseline.read_bytes(), self.matrix.read_bytes()), before)
        self.assertEqual(list((self.root / 'attestations').iterdir()), [])


class CommandTests(unittest.TestCase):
    def test_old_report_returns_clean_cli_error(self):
        import pathlib
        import subprocess
        import sys
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            report = pathlib.Path(directory) / 'report.json'
            report.write_text('{"schema": 1}')
            result = subprocess.run([sys.executable, str(core.ROOT / 'scripts/agent_contracts.py'),
                                     '--mode', 'publish', '--report', str(report)],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Only current-revision verify reports', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
