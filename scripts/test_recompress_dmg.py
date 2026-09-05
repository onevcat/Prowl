import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("recompress-dmg.sh")


class RecompressDMGTests(unittest.TestCase):
    def run_case(self, failure, in_place=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Prowl input.dmg"
            source.write_bytes(b"original image")
            output = source if in_place else root / "Prowl output.dmg"
            if not in_place:
                output.write_bytes(b"previous image")
            tool = root / "hdiutil"
            tool.write_text(
                "#!/bin/bash\n"
                '[[ "$1" == convert && "$3" == -format && "$4" == ULMO && "$5" == -o ]] || exit 90\n'
                'printf "compressed image" > "$6"\n'
                f"exit {failure}\n"
            )
            tool.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), str(source), str(output)],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, failure, result.stderr)
            if not in_place or failure:
                self.assertEqual(source.read_bytes(), b"original image")
            previous = b"original image" if in_place else b"previous image"
            expected = previous if failure else b"compressed image"
            self.assertEqual(output.read_bytes(), expected)
            expected_files = ["Prowl input.dmg", "hdiutil"]
            if not in_place:
                expected_files.insert(1, "Prowl output.dmg")
            self.assertEqual(sorted(p.name for p in root.iterdir()), expected_files)

    def test_success_replaces_output_after_conversion(self):
        self.run_case(0)

    def test_failure_preserves_source_and_previous_output(self):
        self.run_case(23)

    def test_success_replaces_image_in_place(self):
        self.run_case(0, in_place=True)

    def test_failure_preserves_image_in_place(self):
        self.run_case(23, in_place=True)


if __name__ == "__main__":
    unittest.main()
