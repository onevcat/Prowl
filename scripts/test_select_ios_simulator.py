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

        self.assertEqual(
            SELECTOR.destination_for(devices, "iPhone 16 Pro"),
            "platform=iOS Simulator,id=new",
        )

    def test_reports_when_the_requested_simulator_is_not_available(self):
        with self.assertRaisesRegex(ValueError, "iPad Pro"):
            SELECTOR.destination_for({}, "iPad Pro")


if __name__ == "__main__":
    unittest.main()
