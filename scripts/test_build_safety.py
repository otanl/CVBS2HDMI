"""A failed route must not become a packable target on the next make."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildSafetyTest(unittest.TestCase):
    def test_failed_target_is_removed_and_retried(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="tangadc-make-") as directory:
            scratch = Path(directory)
            target = scratch / "failed-route.json"
            fixture = scratch / "failure.mk"
            # Model nextpnr writing JSON, then failing its final timing check.
            fixture.write_text(f"{target}:\n\ttouch $@\n\tfalse\n")
            for _ in range(2):
                result = subprocess.run(
                    ["make", "--no-print-directory", "-f", str(root / "Makefile"),
                     "-f", str(fixture), str(target)], cwd=root,
                    capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("touch", result.stdout)
                self.assertFalse(target.exists(), result.stderr)


if __name__ == "__main__":
    unittest.main()
