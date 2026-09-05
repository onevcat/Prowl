"""Private credentials must never be interpreted as shell input."""
import os
from pathlib import Path
import tempfile
import unittest
import agent_contracts as contracts


class CredentialsTests(unittest.TestCase):
    def test_private_file_and_environment_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'credentials.env'
            path.write_text('# Local keys\nDEEPSEEK_API_KEY="fixture-key"\n')
            path.chmod(0o600)
            self.assertEqual(contracts.load_credentials(path, {}), {'DEEPSEEK_API_KEY': 'fixture-key'})
            self.assertEqual(contracts.load_credentials(path, {'DEEPSEEK_API_KEY': 'exported'})['DEEPSEEK_API_KEY'], 'exported')

    def test_unsafe_permissions_and_shell_syntax_are_rejected_without_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'credentials.env'
            for content, mode in [('KEY=secret', 0o644), ('KEY=$(touch forbidden)', 0o600), ('KEY=secret\nKEY=other', 0o600)]:
                path.write_text(content)
                path.chmod(mode)
                with self.assertRaises(contracts.PolicyError) as error:
                    contracts.load_credentials(path, {})
                self.assertNotIn('secret', str(error.exception))
                self.assertNotIn('forbidden', str(error.exception))

    def test_symlink_rejected_and_missing_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'missing'
            self.assertEqual(contracts.load_credentials(path, {}, required=False), {})
            target = Path(directory) / 'target'
            target.write_text('KEY=fixture')
            target.chmod(0o600)
            path.symlink_to(target)
            with self.assertRaises(contracts.PolicyError):
                contracts.load_credentials(path, {})
