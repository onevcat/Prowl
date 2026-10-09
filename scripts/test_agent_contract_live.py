"""A live pass needs independent response and correlated terminal hook evidence."""
import unittest
import agent_contract_live as live


class EvidenceTests(unittest.TestCase):
    def signal(self, **changes):
        return {'event': 'turn-ended', 'native_event': 'Stop', 'cwd': '/private/probe', 'session_id': 'session', **changes}

    def test_matching_signal(self):
        self.assertTrue(live.accept_signal({'runtime': 'claude', 'token': 'nonce', 'signal': self.signal()}, 'claude', 'nonce', '/private/probe'))

    def test_wrong_identity_or_error_is_never_completion(self):
        for signal in [self.signal(cwd='/elsewhere'), self.signal(session_id=''), self.signal(native_event='StopFailure')]:
            self.assertFalse(live.terminal_signal(signal, '/private/probe'))
        self.assertFalse(live.accept_signal({'runtime': 'pi', 'token': 'nonce', 'signal': self.signal()}, 'claude', 'nonce', '/private/probe'))
        self.assertFalse(live.accept_signal({'runtime': 'claude', 'token': 'stale', 'signal': self.signal()}, 'claude', 'nonce', '/private/probe'))

    def test_exit_or_hook_alone_cannot_pass(self):
        self.assertEqual(live.evaluate(0, False, False, True), 'response_missing')
        self.assertEqual(live.evaluate(0, False, True, False), 'terminal_hook_missing')
        self.assertEqual(live.evaluate(1, False, True, True), 'runtime_failed')
        self.assertEqual(live.evaluate(0, True, True, True), 'runtime_timeout')
        self.assertEqual(live.evaluate(0, False, True, True), 'verified')


class ResponseTests(unittest.TestCase):
    def test_response_accepts_optional_whitespace_but_not_a_longer_number(self):
        self.assertTrue(live.verify_response("RESULT: 9876", "RESULT:9876"))
        self.assertTrue(live.verify_response("RESULT:9876", "RESULT:9876"))
        self.assertFalse(live.verify_response("RESULT:98765", "RESULT:9876"))
        self.assertFalse(live.verify_response("Compute 8137 + 1739", "RESULT:9876"))

    def test_equivalent_directory_aliases(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'target'
            target.mkdir()
            alias = root / 'alias'
            alias.symlink_to(target, target_is_directory=True)
            signal = EvidenceTests().signal(cwd=str(alias))
            self.assertTrue(live.terminal_signal(signal, str(target)))


class ExportTests(unittest.TestCase):
    def test_suite_exports_current_app_resource_directory(self):
        import tempfile
        from pathlib import Path
        from types import SimpleNamespace
        from unittest.mock import patch
        row = dict(runtime='pi', executable='/test/pi', inventory={'status': 'passed'},
                   route={'status': 'configured'})
        binary = SimpleNamespace(path='/test/pi', search_path='/test')
        captured = []

        def export(requests, directory, search_path, timeout):
            captured.extend(requests)
            return ([{'status': 'blocked'} for _ in requests], 'nonce')

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(live, 'runtime_configuration', return_value=('model', [], {})), \
                 patch.object(live, 'export_launches', side_effect=export):
                live.run_suite([row], Path(directory), lambda _: binary, {}, 1, 1, verify=True)
        self.assertEqual(len(captured), 2)
        for request in captured:
            self.assertEqual(Path(request['resources']), live.core.ROOT / 'App/Resources')

    def test_rejects_skipped_zero_stale_and_wrong_runtime(self):
        counts = dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        receipt = dict(schema=1, nonce='current', launches=[{'runtime': 'pi'}])
        requests = [{'runtime': 'pi'}]
        live.validate_export(receipt, counts, 'current', requests)
        for changed in [dict(counts, skippedTests=1), dict(counts, totalTestCount=0), dict(counts, passedTests=True)]:
            with self.assertRaises(live.core.EvidenceError):
                live.validate_export(receipt, changed, 'current', requests)
        for changed in [dict(receipt, nonce='old'), dict(receipt, launches=[{'runtime': 'omp'}])]:
            with self.assertRaises(live.core.EvidenceError):
                live.validate_export(changed, counts, 'current', requests)

    def test_provider_references_and_protocol_guard(self):
        import tempfile, json
        from pathlib import Path
        route = dict(model='deepseek-v4-flash', base_url='https://api.deepseek.com/v1',
                     api_key_env='DEEPSEEK_API_KEY', wire_api='chat-completions')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            live.runtime_configuration('pi', route, root)
            policy = json.loads((root / 'state/models.json').read_text())
            self.assertEqual(policy['providers']['contract']['apiKey'], '${DEEPSEEK_API_KEY}')
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(live.core.PolicyError):
                live.runtime_configuration('codex', route, Path(directory))

    def test_droid_scoped_model_id_cannot_collide_with_a_global_entry(self):
        import tempfile, json
        from pathlib import Path
        route = dict(model='deepseek-v4-flash', base_url='https://api.deepseek.com/v1',
                     api_key_env='DEEPSEEK_API_KEY', wire_api='chat-completions')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model, arguments, _ = live.runtime_configuration('droid', route, root)
            entry = json.loads((root / 'state/settings.json').read_text())['customModels'][0]
            self.assertEqual((model, entry['model'], entry['apiKey']), ('deepseek-v4-flash', 'deepseek-v4-flash', '${DEEPSEEK_API_KEY}'))
            # Droid resolves `custom:<model>` from the user's global settings too; the scoped entry must not share it.
            self.assertNotEqual(entry['id'], 'custom:' + model)
            self.assertEqual(arguments[arguments.index('-m') + 1], entry['id'])


class SocketTests(unittest.TestCase):
    def test_real_transport_frame_and_wrong_token(self):
        import tempfile, socket, struct, json
        from pathlib import Path
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='pwl-test-') as directory:
            path = Path(directory) / 's'
            with live.Collector(path, 'claude', 'current', directory) as collector:
                for token in ['stale', 'current']:
                    payload = {'runtime': 'claude', 'token': token,
                               'signal': EvidenceTests().signal(cwd=directory)}
                    frame = json.dumps({'command': {'agentsHook': {'_0': payload}}}).encode()
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                        client.settimeout(1)
                        client.connect(str(path))
                        client.sendall(struct.pack('>I', len(frame)) + frame)
                        live.Collector.read(client, 6)
                    self.assertEqual(collector.terminal, token == 'current')
            self.assertEqual(len(collector.events), 1)
            self.assertNotIn('token', collector.events[0])
