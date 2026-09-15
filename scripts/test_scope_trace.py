import math
import unittest

from scope_trace import extract_trace, fit_carrier


class ScopeTraceTest(unittest.TestCase):
    def test_position_not_rgb_amplitude(self):
        frame = bytearray(640*480*3)
        for x in range(640):
            value = 20 + x % 121
            y = 479 - (15*value)//8
            for yy in range(y-3, y+4):
                k = (yy*640+x)*3
                frame[k:k+3] = bytes((220, 220, 220) if x % 2 else (220, 20, 20))
        self.assertEqual(extract_trace(frame, legacy_scale=True), [20+x % 121 for x in range(640)])

    def test_full_range(self):
        frame = bytearray(640*480*3)
        for x in range(640):
            value = x % 256
            y = 479-value
            for yy in range(y-3, min(480, y+4)):
                k = (yy*640+x)*3
                frame[k:k+3] = bytes((255, 255, 255))
        self.assertEqual(extract_trace(frame), [x % 256 for x in range(640)])

    def test_missing_frame(self):
        self.assertTrue(all(v is None for v in extract_trace(bytes(640*480*3))))

    def test_ambiguous_snapshot(self):
        frame = bytearray(640*480*3)
        for y in range(300, 307):
            frame[y*640*3:y*640*3+3] = bytes((255, 255, 255))
        self.assertIsNotNone(extract_trace(frame)[0])
        for y in range(400, 407):
            frame[y*640*3:y*640*3+3] = bytes((255, 255, 255))
        self.assertIsNone(extract_trace(frame)[0])

    def test_carrier_fit(self):
        values = [80 + 10*math.cos(2*math.pi*(315e6/88)*3*x/25.2e6)
                     - 6*math.sin(2*math.pi*(315e6/88)*3*x/25.2e6) for x in range(640)]
        values[85] = None
        fit = fit_carrier(values, 240, 300)
        self.assertAlmostEqual(fit["dc"], 80)
        self.assertAlmostEqual(fit["cosine"], 10)
        self.assertAlmostEqual(fit["sine"], -6)
        self.assertLess(fit["rms"], 1e-9)


if __name__ == "__main__":
    unittest.main()
