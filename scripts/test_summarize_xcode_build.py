import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "summarize_xcode_build", Path(__file__).with_name("summarize-xcode-build.py")
)
module = importlib.util.module_from_spec(spec)


class BuildSummaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec.loader.exec_module(module)

    def test_reports_wall_time_separately_from_overlapping_tasks(self):
        log = {
            "duration": 10,
            "subsections": [
                {"title": "Compile A", "duration": 8},
                {"title": "Compile B", "duration": 7},
            ],
            "attachments": [{
                "uniformTypeIdentifier": "com.apple.dt.ActivityLogSectionAttachment.BuildOperationMetrics",
                "data": '{"counters":{"swiftCacheHits":2,"swiftCacheMisses":3}}',
            }],
        }
        result = module.summarize(log, "test.build.json")
        self.assertIn("Build wall time: **10.0 s**", result)
        self.assertIn("swiftCacheHits: 2", result)
        self.assertIn("swiftCacheMisses: 3", result)
        self.assertIn("| Compile A | 8.0 |", result)
        self.assertNotIn("15.0", result)

    def test_missing_metrics_remain_unknown(self):
        result = module.summarize({"duration": 2}, "test.build.json")
        self.assertIn("Cache counters unavailable", result)
        self.assertNotIn("0%", result)

    def test_reports_when_the_test_runner_and_the_first_suite_start(self):
        log = {
            "startTime": 100,
            "duration": 200,
            "subsections": [
                {"title": "Launch actions", "startTime": 100, "subsections": [
                    {"title": "Launch AppTests", "startTime": 140, "subsections": [
                        {"title": "Launching AppTests", "startTime": 140},
                    ]},
                ]},
                {"title": "Test target AppTests", "startTime": 140, "subsections": [
                    {"title": "App (42)", "startTime": 140, "subsections": [
                        {"title": "Run test suite B", "startTime": 231},
                        {"title": "Run test suite A", "startTime": 230},
                    ]},
                ]},
            ],
        }
        result = module.summarize_test_launch(log, "test.action.json")
        self.assertIn("Test action: **200.0 s**", result)
        self.assertIn("Test runner launch starts at **40.0 s**", result)
        self.assertIn("First test suite starts at **130.0 s**", result)

    def test_missing_launch_sections_remain_unknown(self):
        result = module.summarize_test_launch({"startTime": 0, "duration": 5}, "test.action.json")
        self.assertIn("Test runner launch: not recorded", result)
        self.assertIn("First test suite: not recorded", result)


if __name__ == "__main__":
    unittest.main()
