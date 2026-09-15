"""A failed route must not become a packable target on the next make."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildSafetyTest(unittest.TestCase):
    def test_scope_freerun_selects_distinct_logic_and_artifacts(self):
        root = Path(__file__).resolve().parents[1]
        for freerun in (0, 1):
            result = subprocess.run(
                ["make", "--no-print-directory", "-Bn", "ntsc-scope",
                 "NTSC_SCOPE_PHASE=2", "NTSC_SCOPE_RAMP=3",
                 f"NTSC_SCOPE_FREERUN={freerun}"], cwd=root,
                capture_output=True, text=True, check=True)
            self.assertIn(f"-set SCOPE_FREERUN {freerun}", result.stdout)
            stem = f"top_ntsc_hdmi_scope_p2r3f{freerun}"
            for suffix in (".json", "_pnr.json", ".fs"):
                self.assertIn(stem + suffix, result.stdout)

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
