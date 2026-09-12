import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AppBuildPathTests(unittest.TestCase):
    def run_failed_build(self, derived_path):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).resolve().parents[1] / "Makefile", root / "Makefile")
            (root / "overrides.mk").write_text("ensure-ghostty:\n\t@true\n")
            (root / "xcodebuild").write_text(
                '#!/usr/bin/env python3\nimport json, pathlib, sys\n'
                'pathlib.Path("arguments.json").write_text(json.dumps(sys.argv[1:]))\n'
                'sys.exit(23)\n'
            )
            (root / "mise").write_text("#!/bin/sh\ncat\n")
            for name in ["xcodebuild", "mise"]:
                (root / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}")
            env.pop("PROWL_DERIVED_DATA_PATH", None)
            if derived_path is not None:
                env["PROWL_DERIVED_DATA_PATH"] = derived_path
            result = subprocess.run(
                ["make", "-f", "Makefile", "-f", "overrides.mk", "test-app", "SHELL=/bin/bash"],
                cwd=root, env=env, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / "arguments.json").exists(), result.stderr)
            return json.loads((root / "arguments.json").read_text())

    def run_grouped_build(self, fail_mirror=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).resolve().parents[1] / "Makefile", root / "Makefile")
            (root / "overrides.mk").write_text("ensure-ghostty:\n\t@true\n")
            (root / "scripts").mkdir()
            for name in ["assert-xcresult-tests.sh", "print-xcresult-failures.sh"]:
                (root / "scripts" / name).write_text("exit 0\n")
            (root / "xcodebuild").write_text(
                '#!/usr/bin/env python3\nimport json, sys\n'
                'with open("calls.jsonl", "a") as out: out.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                f'fail = {fail_mirror!r} and "-only-testing:supacodeTests/MirrorHostTests" in sys.argv\n'
                'sys.exit(23 if fail else 0)\n'
            )
            (root / "mise").write_text("#!/bin/sh\ncat\n")
            for name in ["xcodebuild", "mise"]:
                (root / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}")
            result = subprocess.run(
                ["make", "-f", "Makefile", "-f", "overrides.mk", "test-app", "SHELL=/bin/bash"],
                cwd=root, env=env, capture_output=True, text=True,
            )
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            return result, calls

    def test_network_suites_run_once_outside_the_bulk_suite(self):
        result, calls = self.run_grouped_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        for suite in ["MirrorHostTests", "MirrorDevicePairingTests", "MirrorConnectionTests",
                      "MirrorTerminalIntegrationTests"]:
            target = f"supacodeTests/{suite}"
            self.assertIn(f"-skip-testing:{target}", calls[0])
            runs = [call for call in calls if f"-only-testing:{target}" in call]
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0][0], "test-without-building")

    def test_network_suite_failure_fails_the_app_test_target(self):
        result, calls = self.run_grouped_build(fail_mirror=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any("-only-testing:supacodeTests/MirrorHostTests" in call for call in calls))

    def test_default_build_reaches_xcodebuild_with_bash_nounset(self):
        arguments = self.run_failed_build(None)
        self.assertNotIn("-derivedDataPath", arguments)
        self.assertEqual(arguments[0], "test")

    def test_explicit_build_path_preserves_spaces_and_failure(self):
        arguments = self.run_failed_build("/tmp/build path")
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], "/tmp/build path")


if __name__ == "__main__":
    unittest.main()
