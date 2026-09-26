#!/usr/bin/env python3
"""Tabulate the ADC_DIAG strip: per rotation and per bit, how often the
rising-edge and falling-edge reads of the same pin disagree.

Records SECONDS of video from the capture card, cropped to the strip, so a
whole 0..9 rotation cycle (6.7 s) costs a few megabytes instead of hundreds
of PNGs.  Strip word (rows 472..475): 101, bit, rotation, x/16, y/16 --
x: the sample against the next falling read; y: the falling read against the
next sample.  A pair that never straddles the converter's output switching
reads 0; one that always does reads the fraction of conversions in which that
bit changes.

    python3 scripts/adc_diag.py OUT.raw [SECONDS]      record, then tabulate
    python3 scripts/adc_diag.py OUT.raw --table        tabulate an existing one
"""
import statistics
import subprocess
import sys

W, ROWS = 640, 8          # crop: y = 472..479


def record(path, seconds):
    # A frame count, not a duration, and passthrough timing: when the card's
    # timestamps jumped, "-t" with the default constant-rate output padded the
    # gap with duplicates and wrote 48 GB before the disk filled.
    subprocess.check_call(
        ["ffmpeg", "-v", "error", "-y", "-f", "avfoundation", "-video_size", "640x480",
         "-framerate", "60", "-pixel_format", "uyvy422", "-i", "0",
         "-frames:v", str(int(seconds * 60)), "-fps_mode", "passthrough",
         "-vf", "crop=640:8:0:472", "-f", "rawvideo", "-pix_fmt", "rgb24", path])


def word(frame, rows):
    value = 0
    for cell in range(32):
        levels = [frame[(y * W + x) * 3 + c] for y in rows
                  for x in range(cell * 16 + 6, cell * 16 + 10) for c in range(3)]
        level = statistics.median(levels)
        if 70 < level < 180:
            return None
        value = (value << 1) | (level >= 180)
    return value


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    if len(sys.argv) < 3 or sys.argv[2] != "--table":
        record(path, float(sys.argv[2]) if len(sys.argv) > 2 else 8.0)
    data = open(path, "rb").read()
    size = W * ROWS * 3
    cells = {}
    frames = len(data) // size
    for i in range(frames):
        f = data[i * size:(i + 1) * size]
        w = word(f, (1, 2))
        if w is None or w >> 29 != 0b101:
            continue
        bit, rot = (w >> 26) & 7, (w >> 22) & 15
        x, y = ((w >> 11) & 0x7FF) * 16, (w & 0x7FF) * 16
        cells.setdefault((rot, bit), []).append((x, y))
    print("%d frames, %d decoded" % (frames, sum(len(v) for v in cells.values())))
    print("rot | " + " | ".join("bit%d  x/y %%" % b for b in range(8)))
    for rot in range(10):
        row = []
        for bit in range(8):
            v = cells.get((rot, bit))
            if not v:
                row.append("    --    ")
                continue
            x = statistics.median(a for a, _ in v) * 100.0 / 16384
            y = statistics.median(b for _, b in v) * 100.0 / 16384
            row.append("%4.0f/%-4.0f" % (x, y))
        print("%3d | %s" % (rot, " | ".join(row)))


if __name__ == "__main__":
    main()
