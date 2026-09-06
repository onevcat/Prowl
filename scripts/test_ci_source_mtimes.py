import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

spec = importlib.util.spec_from_file_location(
    "ci_source_mtimes", Path(__file__).with_name("ci-source-mtimes.py")
)
module = importlib.util.module_from_spec(spec)


class SourceMtimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec.loader.exec_module(module)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "Source.swift"
        self.source.write_text("let value = 1\n")
        os.utime(self.source, ns=(1000000000, 1000000000))
        self.manifest = self.root / "manifest.json"

    def save(self):
        module.save(self.root, ["Source.swift"], self.manifest)

    def test_app_scope_excludes_cli_owned_inputs(self):
        files = ["Package.swift", "supacode/CLIService/Shared/Model.swift",
                 "supacode/Support/Model.swift", "supacodeTests/ModelTests.swift"]
        for name in files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("source")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "--", *files], check=True)
        app = set(module.tracked_inputs(self.root, "app"))
        cli = set(module.tracked_inputs(self.root, "cli"))
        self.assertEqual(app, {"supacode/Support/Model.swift", "supacodeTests/ModelTests.swift"})
        self.assertFalse(app & cli)

    def test_restores_only_identical_content(self):
        self.save()
        os.utime(self.source, ns=(2000000000, 2000000000))
        self.assertEqual(module.restore(self.root, ["Source.swift"], self.manifest), 1)
        self.assertEqual(self.source.stat().st_mtime_ns, 1000000000)

    def test_changed_content_keeps_new_time_even_with_same_size(self):
        self.save()
        self.source.write_text("let value = 2\n")
        os.utime(self.source, ns=(2000000000, 2000000000))
        self.assertEqual(module.restore(self.root, ["Source.swift"], self.manifest), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, 2000000000)

    def test_new_and_deleted_files_are_not_restored(self):
        self.save()
        self.source.unlink()
        (self.root / "New.swift").write_text("new")
        self.assertEqual(module.restore(self.root, ["New.swift"], self.manifest), 0)

    def test_missing_or_invalid_manifest_is_a_cache_miss(self):
        self.assertEqual(module.restore(self.root, ["Source.swift"], self.manifest), 0)
        self.manifest.write_text("invalid")
        self.assertEqual(module.restore(self.root, ["Source.swift"], self.manifest), 0)

    def test_unlisted_paths_and_symlinks_are_not_restored(self):
        self.save()
        os.utime(self.source, ns=(2000000000, 2000000000))
        self.assertEqual(module.restore(self.root, [], self.manifest), 0)
        (self.root / "Link.swift").symlink_to(self.source)
        self.assertEqual(module.restore(self.root, ["Link.swift", "../Source.swift"], self.manifest), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, 2000000000)

    def test_wrong_workspace_does_not_restore(self):
        self.save()
        data = json.loads(self.manifest.read_text())
        data["root"] = "/different/workspace"
        self.manifest.write_text(json.dumps(data))
        self.assertEqual(module.restore(self.root, ["Source.swift"], self.manifest), 0)


if __name__ == "__main__":
    unittest.main()
