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


if __name__ == "__main__":
    unittest.main()
