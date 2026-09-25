#!/usr/bin/env python3
"""Read the converter interface's state off captured HDMI frames.

The decoder draws a 32-bit word in the bottom four rows of the picture
(y = 476..479), 32 cells of 16 pixels, most significant bit first, white = 1:

    A (4 bits) | rotation (4) | calibrated | pair x | sweeps (6) | track count (16)

The track count is the number of samples, in the last 16384, whose falling-
edge read differed from the rising-edge read on the pair the chosen rotation
is quiet on -- near zero when the read is clean.  Sweeps counts calibrations
run since reset; one that keeps rising means the calibration keeps losing the
read and starting again.

    python3 scripts/adc_strip.py 'build/cap_*.png'
"""
import glob
import statistics
import subprocess
import sys

W, H = 640, 480


def frame(path):
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-i", path, "-frames:v", "1",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
    if len(raw) != W * H * 3:
        raise ValueError("%s is not a 640x480 frame" % path)
    return raw


def word(raw, rows=(477, 478), marker=0xA):
    """The strip's word, or None if a cell is neither black nor white."""
    value = 0
    for cell in range(32):
        levels = [raw[(y * W + x) * 3 + c] for y in rows
                  for x in range(cell * 16 + 6, cell * 16 + 10) for c in range(3)]
        level = statistics.median(levels)
        if 70 < level < 180:
            return None
        value = (value << 1) | (level >= 180)
    return value if value >> 28 == marker else None


def fields(w):
    return dict(rot=(w >> 24) & 15, cal=(w >> 23) & 1, pair="x" if (w >> 22) & 1 else "y",
                sweeps=(w >> 16) & 63, track=w & 0xFFFF)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    paths = sorted(glob.glob(sys.argv[1]))
    got = []
    per_rot = {}
    for p in paths:
        raw = frame(p)
        w2 = word(raw, (473, 474), 0x5)
        if w2 is not None:
            per_rot.setdefault((w2 >> 24) & 15, set()).add(((w2 >> 12) & 0xFFF, w2 & 0xFFF))
        w = word(raw)
        if w is None:
            print("%s: no strip" % p)
            continue
        got.append(fields(w))
    for r in sorted(per_rot):
        print("rotation %d: last sweep x/y counts %s" % (r, sorted(
            ("%d/%d" % (8 * a, 8 * b)) for a, b in per_rot[r])))
    if not got:
        raise SystemExit("no frame carried the strip")
    for key in ("rot", "cal", "pair", "sweeps"):
        print("%-7s %s" % (key, sorted(set(g[key] for g in got))))
    tracks = [g["track"] for g in got]
    print("track   min %d median %d max %d (of 16384)"
          % (min(tracks), statistics.median(tracks), max(tracks)))
    print("frames  %d of %d carried the strip" % (len(got), len(paths)))


if __name__ == "__main__":
    main()
