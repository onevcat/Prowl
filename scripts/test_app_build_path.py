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

    def test_default_build_reaches_xcodebuild_with_bash_nounset(self):
        arguments = self.run_failed_build(None)
        self.assertNotIn("-derivedDataPath", arguments)
        self.assertEqual(arguments[0], "test")

    def test_explicit_build_path_preserves_spaces_and_failure(self):
        arguments = self.run_failed_build("/tmp/build path")
        self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1], "/tmp/build path")


if __name__ == "__main__":
    unittest.main()
