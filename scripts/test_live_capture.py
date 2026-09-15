import unittest

from live_capture import live_reason
from scope_trace import scope_identity, extract_trace


class LiveCaptureTest(unittest.TestCase):
    def test_header_decoding_and_trace_separation(self):
        data = bytearray(640*480*3)
        word = (0xA5 << 24) | (2 << 20) | (4 << 17) | (254 << 8) | 1
        for cell in range(32):
            colour = bytes([230 if (word >> (31-cell)) & 1 else 15])*3
            for y in range(200, 208):
                for x in range(cell*16, (cell+1)*16):
                    data[(y*640+x)*3:(y*640+x+1)*3] = colour
        self.assertEqual(scope_identity(data), dict(mode=2, phase=4, frame=254, version=1))
        self.assertTrue(all(v is None for v in extract_trace(data)))

    def test_old_frame_has_no_identity(self):
        self.assertIsNone(scope_identity(bytes(640*480*3)))

    def test_frozen_pixels(self):
        self.assertIsNotNone(live_reason(['a']*12, [None]*12))

    def test_stale_tail_despite_live_start(self):
        self.assertIsNotNone(live_reason(list('abcd')+['x']*8, [None]*12))

    def test_live_video(self):
        self.assertIsNone(live_reason(list('abcd')*3, [None]*12))

    def test_live_scope_wrap_and_expected_mode(self):
        ids = [dict(mode=2, phase=4, frame=f) for f in [254, 255, 0, 1]]
        self.assertIsNone(live_reason(list('abcd'), ids, 2, 4))
        self.assertIsNotNone(live_reason(list('abcd'), ids, 3, 4))
        self.assertIsNotNone(live_reason(list('abcd'), ids, 2, 2))

    def test_frozen_scope_despite_changing_pixels(self):
        ids = [dict(mode=2, phase=4, frame=1)]*12
        self.assertIsNotNone(live_reason(list('abcdefghijkl'), ids, 2, 4))

    def test_expected_scope_rejects_old_and_mixed_frames(self):
        ids = [dict(mode=2, phase=4, frame=f) for f in range(4)]
        self.assertIsNotNone(live_reason(list('abcd'), [None]*4, 2, 4))
        ids[0] = None
        self.assertIsNotNone(live_reason(list('abcd'), ids, 2, 4))


if __name__ == '__main__':
    unittest.main()
