import pathlib
import re
import unittest


class AgentWaitScreenProviderTests(unittest.TestCase):
    def test_wait_screen_uses_detection_buffer(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "App" / "Sources" / "App" / "ProwlApp.swift").read_text()
        match = re.search(
            r"screenProvider:\s*\{ target in(?P<body>.*?)\n\s*\}\n\s*\)",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "Agent wait screenProvider composition was not found")
        body = match.group("body")
        self.assertIn("readActiveContentsForCLI()", body)
        self.assertNotIn("readScreenContentsForCLI()", body)


if __name__ == "__main__":
    unittest.main()
