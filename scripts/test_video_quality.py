import unittest

from video_quality import measure_frame


class VideoQualityTest(unittest.TestCase):
    def frame(self, bars=None):
        if bars is None:
            bars = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
                    (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]
        return b"".join(bytes(p)*80 for p in bars)*4

    def measure(self, data):
        return measure_frame(data, 640, 4, (0, 3), 0, 80)

    def test_clean_bars(self):
        result = self.measure(self.frame())
        self.assertEqual(result["correct"], 3)
        self.assertEqual(result["colour_rows"], 3)
        self.assertEqual(result["saturated_channels"], 0)

    def test_drop_not_hidden_by_median(self):
        data = bytearray(self.frame())
        data[640*3:640*6] = bytes(640*3)
        result = self.measure(data)
        self.assertEqual(result["correct"], 2)
        self.assertEqual(result["dropped"], 1)

    def test_wrong_order(self):
        data = bytearray(self.frame())
        data[80*3:80*6], data[80*9:80*12] = data[80*9:80*12], data[80*3:80*6]
        result = self.measure(data)
        self.assertEqual(result["wrong_order"], 1)

    def test_excludes_bottom_ramp(self):
        data = bytearray(self.frame())
        data[640*9:] = bytes(640*3)
        self.assertEqual(self.measure(data)["correct"], 3)

    def test_monochrome_is_not_colour(self):
        result = self.measure(self.frame([(v, v, v) for v in range(210, 0, -30)] + [(0, 0, 0)]))
        self.assertEqual(result["colour_rows"], 0)


if __name__ == "__main__":
    unittest.main()
