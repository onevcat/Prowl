"""Zero-inference entry point, model policy, and preflight evidence regressions."""

from __future__ import annotations

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

import agent_contracts as contracts
import agent_versions as versions


def route(**changes):
    return {
        "provider": "deepseek",
        "model": "deepseek-v4-flash",
        "base_url": "https://api.deepseek.com",
        "wire_api": "responses",
        "api_key_env": "DEEPSEEK_API_KEY",
        **changes,
    }


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "policy.json"

    def load(self, document):
        self.path.write_text(json.dumps(document))
        return contracts.load_policy(self.path)

    def test_missing_default_policy_is_reported_without_creating_it(self):
        self.assertEqual(contracts.load_policy(self.path, required=False), {})
        self.assertFalse(self.path.exists())

    def test_explicit_missing_policy_is_an_error(self):
        with self.assertRaises(contracts.PolicyError):
            contracts.load_policy(self.path)

    def test_valid_route_keeps_only_a_credential_reference(self):
        policy = self.load({"schema": 1, "runtimes": {"codex": route()}})
        self.assertEqual(policy["codex"], route())

    def test_schema_typos_and_unsafe_values_fail_without_echoing_secrets(self):
        secret = "SECRET_VALUE_MUST_NOT_APPEAR"
        cases = [
            {"schema": True, "runtimes": {}},
            {"schema": 2, "runtimes": {}},
            {"schema": 1, "runtimes": {}, "unknown": secret},
            {"schema": 1, "runtimes": {"unknown": route()}},
            {"schema": 1, "runtimes": {"codex": route(api_key=secret)}},
            {"schema": 1, "runtimes": {"codex": route(api_key_env=f"$(echo {secret})")}},
            {"schema": 1, "runtimes": {"codex": route(base_url=f"https://user:{secret}@example.com")}},
            {"schema": 1, "runtimes": {"codex": route(base_url=f"https://example.com?key={secret}")}},
            {"schema": 1, "runtimes": {"codex": route(base_url="http://external.example.com")}},
            {"schema": 1, "runtimes": {"codex": route(model="auto")}},
            {"schema": 1, "runtimes": {"codex": route(wire_api="unknown")}},
            {"schema": 1, "runtimes": {"codex": route(model=[secret])}},
        ]
        for document in cases:
            with self.subTest(document=document):
                with self.assertRaises(contracts.PolicyError) as caught:
                    self.load(document)
                self.assertNotIn(secret, str(caught.exception))

    def test_duplicate_keys_are_rejected(self):
        self.path.write_text('{"schema":1,"schema":1,"runtimes":{}}')
        with self.assertRaises(contracts.PolicyError):
            contracts.load_policy(self.path)

    def test_oversized_policy_is_rejected(self):
        self.path.write_text(" " * (contracts.MAX_POLICY_BYTES + 1))
        with self.assertRaises(contracts.PolicyError):
            contracts.load_policy(self.path)

    def test_key_presence_never_serializes_the_value(self):
        status = contracts.route_status(route(), {"DEEPSEEK_API_KEY": "secret-key"})
        self.assertEqual(status["status"], "configured")
        self.assertTrue(status["credential_present"])
        self.assertNotIn("secret-key", json.dumps(status))
        self.assertEqual(contracts.route_status(route(), {})["status"], "credential_missing")
        self.assertEqual(contracts.route_status(None, {})["status"], "not_configured")

    def test_keyless_route_does_not_claim_remote_authentication(self):
        status = contracts.route_status(route(api_key_env=None, base_url="http://127.0.0.1:1234/v1"), {})
        self.assertEqual(status["status"], "configured")
        self.assertIsNone(status["credential_present"])


class InventoryTests(unittest.TestCase):
    def entries(self):
        return versions.load_attestation(versions.ATTESTATION_PATH)

    def test_inventory_only_runs_version_commands_and_never_reports_live_success(self):
        commands = []

        def run(command, search_path, timeout):
            commands.append(tuple(command))
            return versions.CommandResult("100.0.0\n", "secret stderr", 0, False)

        result = contracts.inventory(
            self.entries(), {}, {},
            resolve=lambda name: versions.ResolvedBinary(f"/tools/{name}", "path", "/tools"),
            run=run,
        )
        self.assertEqual(len(commands), 8)
        self.assertTrue(all(command[1:] == ("--version",) for command in commands))
        self.assertTrue(all(row["inventory"]["status"] == "passed" for row in result))
        self.assertTrue(all(row["live"]["status"] == "not_run" for row in result))
        self.assertNotIn("secret stderr", json.dumps(result))

    def test_version_text_on_nonzero_exit_is_not_a_pass(self):
        result = contracts.inventory(
            self.entries()[:1], {}, {},
            resolve=lambda name: versions.ResolvedBinary("/tools/agent", "path", "/tools"),
            run=lambda *args: versions.CommandResult("2.1.260", "secret", 1, False),
        )
        self.assertEqual(result[0]["inventory"]["status"], "blocked")
        self.assertEqual(result[0]["inventory"]["reason"], "version_command_failed")

    def test_missing_binary_timeout_and_unparseable_are_distinct(self):
        cases = [
            (None, None, "blocked", "binary_missing"),
            ("/agent", versions.CommandResult("", "", None, True), "timed_out", "version_timeout"),
            ("/agent", versions.CommandResult("not a version", "secret", 0, False), "blocked", "version_unparseable"),
        ]
        for path, output, status, reason in cases:
            with self.subTest(reason=reason):
                rows = contracts.inventory(
                    self.entries()[:1], {}, {},
                    resolve=lambda name: versions.ResolvedBinary(path, "path", "/tools") if path else None,
                    run=lambda *args: output,
                )
                self.assertEqual(rows[0]["inventory"], {"status": status, "reason": reason})
                self.assertNotIn("secret", json.dumps(rows))

    def test_child_environment_drops_credentials_and_active_session_identity(self):
        inherited = {
            "HOME": "/actual/home", "PATH": "/tools", "SHELL": "/bin/zsh",
            "DEEPSEEK_API_KEY": "secret", "PROWL_PANE_ID": "real-pane",
            "PROWL_WORKFLOW_TOKEN": "real-token", "CODEX_HOME": "/real/codex",
            "TEST_RUNNER_PROWL_RUN_LIVE_CODEX_CONTRACT": "1",
        }
        clean = contracts.probe_environment(inherited, "/other/tools")
        self.assertEqual(clean["HOME"], "/actual/home")
        self.assertEqual(clean["PATH"], "/other/tools")
        self.assertNotIn("secret", json.dumps(clean))
        self.assertFalse(any(key.startswith(("PROWL_", "TEST_RUNNER_")) for key in clean))
        self.assertNotIn("CODEX_HOME", clean)


class PreflightEvidenceTests(unittest.TestCase):
    def evidence(self):
        return {
            "schema": 1, "mode": "preflight", "runtime": "codex", "nonce": "this-run",
            "executable": "/tools/codex", "scenarios": list(contracts.CODEX_SCENARIOS),
        }

    def summary(self):
        return {"result": "Passed", "totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}

    def test_requires_receipt_and_one_executed_test(self):
        contracts.validate_preflight(self.evidence(), self.summary(), "this-run", "/tools/codex")

    def test_green_process_cannot_hide_zero_skipped_or_failed_tests(self):
        for changes in [
            {"totalTestCount": 0, "passedTests": 0},
            {"passedTests": 0, "skippedTests": 1},
            {"failedTests": 1}, {"totalTestCount": 2}, {"result": "Failed"},
        ]:
            with self.subTest(changes=changes), self.assertRaises(contracts.EvidenceError):
                contracts.validate_preflight(self.evidence(), {**self.summary(), **changes}, "this-run", "/tools/codex")

    def test_rejects_stale_wrong_binary_and_partial_receipts(self):
        for changes in [{"nonce": "old-run"}, {"executable": "/other/codex"}, {"scenarios": ["base"]}, {"mode": "live"}]:
            with self.subTest(changes=changes), self.assertRaises(contracts.EvidenceError):
                contracts.validate_preflight({**self.evidence(), **changes}, self.summary(), "this-run", "/tools/codex")


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "commands"
        binary = self.bin / "codex"
        binary.write_text(f'#!/bin/sh\necho "$*" >> "{self.capture}"\necho "codex-cli 0.153.2"\n')
        binary.chmod(0o700)
        self.env = {**os.environ, "PATH": str(self.bin), "DEEPSEEK_API_KEY": "secret-value"}
        self.output = self.root / "results"
        self.policy = self.root / "empty-policy.json"
        self.credentials = self.root / "credentials.env"
        self.credentials.touch(mode=0o600)
        self.policy.write_text('{"schema":1,"runtimes":{}}')

    def invoke(self, *args):
        return subprocess.run(
            [sys.executable, str(contracts.__file__), "--runtime", "codex", "--no-login-shell",
             "--output-dir", str(self.output), "--config", str(self.policy), "--credentials", str(self.credentials), "--json", *args],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def test_default_cli_is_zero_inference_and_writes_private_report(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["mode"], "inventory")
        self.assertFalse(report["release_ready"])
        self.assertEqual(report["runtimes"][0]["route"]["status"], "not_configured")
        self.assertEqual(self.capture.read_text(), "--version\n")
        saved = pathlib.Path(report["report_path"])
        self.assertEqual(json.loads(saved.read_text()), report)
        self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o600)
        self.assertNotIn("secret-value", result.stdout + result.stderr)

    def test_live_flag_is_rejected_before_any_agent_starts(self):
        result = self.invoke("--live")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())

    def test_invalid_config_is_rejected_before_any_agent_starts(self):
        config = self.root / "invalid.json"
        config.write_text('{"api_key":"secret-value"}')
        result = self.invoke("--config", str(config))
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("secret-value", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_repeated_runs_keep_distinct_reports(self):
        first = json.loads(self.invoke().stdout)
        second = json.loads(self.invoke().stdout)
        self.assertNotEqual(first["report_path"], second["report_path"])
        self.assertTrue(pathlib.Path(first["report_path"]).exists())

    def test_committed_example_contains_only_supported_secret_free_routes(self):
        policy = contracts.load_policy(contracts.ROOT / "Config/agent-contracts.example.json")
        self.assertEqual(set(policy), set(versions.TIER_A_RUNTIMES) - {"qodercli"})
        self.assertTrue(all(value["api_key_env"] == "DEEPSEEK_API_KEY" for value in policy.values()))

    def test_version_timeout_is_reported_and_not_included_as_live_evidence(self):
        binary = self.bin / "codex"
        binary.write_text('#!/bin/sh\nexec /bin/sleep 10\n')
        result = self.invoke("--timeout", "0.05", "--strict")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["runtimes"][0]["inventory"]["status"], "timed_out")
        self.assertEqual(report["runtimes"][0]["live"]["status"], "not_run")

    def test_strict_inventory_fails_on_missing_route_but_not_version_drift(self):
        self.assertEqual(self.invoke("--strict").returncode, 1)
        config = self.root / "policy.json"
        config.write_text(json.dumps({"schema": 1, "runtimes": {"codex": route()}}))
        result = self.invoke("--strict", "--config", str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["runtimes"][0]["version_status"], "newer")


if __name__ == "__main__":
    unittest.main()
