from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class IOSMirrorConfigurationTests(unittest.TestCase):
    def test_iphone_supports_the_landscape_orientations_used_by_ui_tests(self):
        xcconfig = (ROOT / "Mirror/iOS/Config/App.xcconfig").read_text()
        expected = (
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "
            "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        )
        self.assertIn(expected, xcconfig)

    def test_ui_tests_launch_before_requesting_an_orientation(self):
        ui_tests = (ROOT / "Mirror/iOS/ProwlMirror-iOSUITests/ProwlMirror_iOSUITests.swift").read_text()
        self.assertNotIn(
            "XCUIDevice.shared.orientation = .landscapeLeft\n    app.launch()",
            ui_tests,
        )
