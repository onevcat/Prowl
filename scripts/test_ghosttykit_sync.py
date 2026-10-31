import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[1]
PINNED_SHA = "5a6f0446160ef0b4806c7fc19e3f212324c2c0d9"
OTHER_SHA = "6ae1993379cf06f4e6ee9784b60c0e1e75b01ae1"


def run_git(root, *arguments):
    subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)


def make_pinned_checkout(root):
    run_git(root, "init", "-q")
    run_git(root, "update-index", "--add", "--cacheinfo", f"160000,{PINNED_SHA},ThirdParty/ghostty")
    run_git(
        root, "-c", "user.name=test", "-c", "user.email=test@example.com",
        "commit", "-q", "-m", "Pin Ghostty",
    )


class EnsureArtifactsTests(unittest.TestCase):
    def run_ensure(self, installed_sha):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_pinned_checkout(root)
            (root / "scripts").mkdir()
            script = root / "scripts/ensure-ghosttykit-artifacts.sh"
            shutil.copyfile(REPOSITORY / "scripts/ensure-ghosttykit-artifacts.sh", script)
            script.chmod(0o755)
            framework = root / "App/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64"
            framework.mkdir(parents=True)
            (framework / "ghostty-internal.a").write_bytes(
                b"\x00\x01version\x001.4.0-release-v1-4-0-patched+" + installed_sha[:9].encode() + b"\x00"
            )
            (root / "App/Resources/ghostty").mkdir(parents=True)
            (root / "App/Resources/terminfo").mkdir(parents=True)
            hash_file = root / ".ghostty_hash"
            hash_file.write_text(f"{PINNED_SHA}\n")
            env = dict(os.environ, PROWL_GHOSTTY_NO_PREBUILT="1", HOME=str(root))
            env.pop("PROWL_GHOSTTY_SOURCE_DIR", None)
            result = subprocess.run([str(script)], cwd=root, env=env, capture_output=True, text=True)
            return result, hash_file.exists()

    def test_accepts_framework_built_from_the_pin(self):
        result, hash_kept = self.run_ensure(PINNED_SHA)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("up-to-date", result.stdout)
        self.assertTrue(hash_kept)

    def test_replaces_framework_from_another_commit_despite_matching_hash(self):
        result, hash_kept = self.run_ensure(OTHER_SHA)
        # Exit status 2 asks the Makefile for a local build, because this test disables the download.
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("does not match", result.stdout)
        self.assertFalse(hash_kept)


class MakefileTests(unittest.TestCase):
    def test_release_targets_sync_ghostty_to_the_pin(self):
        makefile = (REPOSITORY / "Makefile").read_text()
        for target in ["archive", "install-release"]:
            rule = re.search(rf"^{target}:([^#\n]*)", makefile, re.MULTILINE)
            self.assertIsNotNone(rule, target)
            prerequisites = rule.group(1).split()
            self.assertIn("ensure-ghostty", prerequisites, target)
            self.assertNotIn("build-ghostty-xcframework", prerequisites, target)

    def test_hash_is_not_recorded_when_nothing_is_rebuilt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_pinned_checkout(root)
            shutil.copyfile(REPOSITORY / "Makefile", root / "Makefile")
            (root / ".ghostty_build_stamp").touch()
            result = subprocess.run(
                ["make", "-f", "Makefile", "build-ghostty-xcframework", "SHELL=/bin/bash"],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / ".ghostty_hash").exists())


class VerifyBundledGhosttyTests(unittest.TestCase):
    def run_verify(self, version_line):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Prowl.app"
            if version_line is not None:
                entry = app / "Contents/MacOS/ghostty"
                entry.parent.mkdir(parents=True)
                entry.write_text(f'#!/bin/sh\n[ "$1" = "+version" ] || exit 9\necho "{version_line}"\necho\n')
                entry.chmod(0o755)
            return subprocess.run(
                [str(REPOSITORY / "scripts/verify-bundled-ghostty.sh"), str(app), PINNED_SHA],
                capture_output=True, text=True,
            )

    def test_accepts_the_pinned_engine(self):
        result = self.run_verify("Ghostty 1.4.0-release-v1-4-0-patched+5a6f04461")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_another_engine(self):
        result = self.run_verify("Ghostty 1.3.2-rehearsal-tip-9d479dcb1-patched+6ae199337")
        self.assertEqual(result.returncode, 1)
        self.assertIn("6ae199337", result.stderr)
        self.assertIn("5a6f04461", result.stderr)

    def test_rejects_a_bundle_without_the_entry(self):
        result = self.run_verify(None)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
