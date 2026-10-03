from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DeveloperOnboardingTests(unittest.TestCase):
    def test_root_readme_has_a_fresh_clone_path_and_real_make_targets(self):
        readme = (ROOT / "README.md").read_text()

        self.assertIn(
            "git clone --recurse-submodules https://github.com/onevcat/Prowl.git",
            readme,
        )
        self.assertIn("make run-app                     # Build and launch Debug from Xcode build products", readme)
        self.assertIn("make install-dev-build           # Build Debug and install to /Applications/Prowl Debug.app", readme)
        self.assertNotIn("make install-debug", readme)

    def test_mirror_readmes_describe_revision_matched_hosts(self):
        expected = "same revision (or a matching Prowl release)"
        for relative_path in ("Mirror/iOS/README.md", "Mirror/Android/README.md"):
            with self.subTest(relative_path=relative_path):
                readme = (ROOT / relative_path).read_text()
                self.assertIn(expected, readme)
                self.assertNotIn("feat/mobile-mirror", readme)

    def test_ios_readme_has_a_repeatable_cross_device_test_command(self):
        readme = (ROOT / "Mirror/iOS/README.md").read_text()
        self.assertIn("make test-mirror-ios", readme)
        self.assertIn("matching simulator form factors", readme)

    def test_android_readme_accepts_android_studios_bundled_jbr(self):
        readme = (ROOT / "Mirror/Android/README.md").read_text()
        self.assertIn("Android Studio's bundled JBR or JDK 17", readme)
