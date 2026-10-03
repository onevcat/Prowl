import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("select_ios_simulator.py")
SPEC = importlib.util.spec_from_file_location("select_ios_simulator", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)


class SelectIOSSimulatorTests(unittest.TestCase):
    def test_chooses_the_newest_available_ios_runtime(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16 Pro", "udid": "old", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 16 Pro", "udid": "new", "isAvailable": True},
                {"name": "iPhone 16 Pro", "udid": "unavailable", "isAvailable": False},
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [
                {"name": "iPhone 16 Pro", "udid": "not-ios", "isAvailable": True},
            ],
        }

        simulator = SELECTOR.select_simulator(devices, r"iPhone [0-9]+ Pro")
        self.assertEqual(simulator.udid, "new")
        self.assertEqual(simulator.destination, "platform=iOS Simulator,id=new")

    def test_skips_runtimes_newer_than_the_sdk(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone 17 Pro", "udid": "supported", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name": "iPhone 17 Pro", "udid": "too-new", "isAvailable": True},
            ],
        }

        simulator = SELECTOR.select_simulator(devices, r"iPhone [0-9]+ Pro", max_runtime=(26, 5, 0))
        self.assertEqual(simulator.udid, "supported")

    def test_prefers_the_newest_model_that_matches_the_whole_name(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone 9 Pro", "udid": "iphone-9", "isAvailable": True},
                {"name": "iPhone 17 Pro", "udid": "iphone-17", "isAvailable": True},
                {"name": "iPhone 18 Pro Max", "udid": "max", "isAvailable": True},
                {"name": "iPad Pro 11-inch (M4)", "udid": "m4", "isAvailable": True},
                {"name": "iPad Pro 11-inch (M5)", "udid": "m5", "isAvailable": True},
                {"name": "iPad Pro 13-inch (M5)", "udid": "13-inch", "isAvailable": True},
            ],
        }

        self.assertEqual(SELECTOR.select_simulator(devices, r"iPhone [0-9]+ Pro").udid, "iphone-17")
        self.assertEqual(SELECTOR.select_simulator(devices, r"iPad Pro 11-inch \(M[0-9]+\)").udid, "m5")

    def test_reports_when_no_simulator_matches(self):
        with self.assertRaisesRegex(ValueError, "iPad Pro"):
            SELECTOR.select_simulator({}, r"iPad Pro 11-inch \(M[0-9]+\)")

    def test_reads_the_sdk_version_as_a_runtime_version(self):
        self.assertEqual(SELECTOR.parse_version("26.5"), (26, 5, 0))
        self.assertEqual(SELECTOR.parse_version("26.0.1"), (26, 0, 1))


if __name__ == "__main__":
    unittest.main()
