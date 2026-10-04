import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "ci_test_watchdog", Path(__file__).with_name("ci-test-watchdog.py")
)
module = importlib.util.module_from_spec(spec)

RESULTS = "/work/Prowl/build/test-results/"
PRODUCTS = "/work/Prowl/build/ci-derived-data/Build/Products"
PS_OUTPUT = f"""\
  101 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -workspace Prowl.xcworkspace -resultBundlePath {RESULTS}prowl-tests.xcresult
  102 tee {RESULTS}prowl-tests.xcresult.log
  103 /bin/sh -c set -euo pipefail; xcodebuild test -resultBundlePath {RESULTS}prowl-tests.xcresult
  104 {PRODUCTS}/Debug/Prowl Debug.app/Contents/MacOS/Prowl Debug -NSTreatUnknownArgumentsAsOpen NO
  105 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project Other.xcodeproj
  106 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest /tmp/Other.xctest
  107 python3 scripts/ci-test-watchdog.py --products {PRODUCTS}
"""


class WatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec.loader.exec_module(module)

    def test_output_is_stalled_only_after_the_silence_limit(self):
        self.assertFalse(module.stalled(newest=1000, now=1599, silence=600))
        self.assertTrue(module.stalled(newest=1000, now=1600, silence=600))

    def test_no_output_yet_is_not_a_stall(self):
        self.assertFalse(module.stalled(newest=None, now=5000, silence=600))

    def test_newest_output_uses_the_latest_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tmp, "a.xcresult.log")
            new = Path(tmp, "b.xcresult.log")
            old.write_text("old")
            new.write_text("new")
            os.utime(old, (100, 100))
            os.utime(new, (200, 200))
            self.assertEqual(module.newest_output([str(old), str(new)]), 200)
            self.assertIsNone(module.newest_output([]))

    def test_interrupts_only_xcodebuild_runs_that_write_to_the_results_folder(self):
        processes = module.parse_processes(PS_OUTPUT)
        self.assertEqual(module.xcodebuild_pids(processes, RESULTS), [101])

    def test_samples_xcodebuild_and_the_test_processes_but_not_itself(self):
        processes = module.parse_processes(PS_OUTPUT)
        targets = module.sample_targets(processes, RESULTS, [PRODUCTS], own_pid=107)
        self.assertEqual([pid for pid, _ in targets], [101, 104, 106])


if __name__ == "__main__":
    unittest.main()
