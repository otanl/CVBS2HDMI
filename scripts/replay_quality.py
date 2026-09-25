#!/usr/bin/env python3
"""Score the lines sim/replay_tb.v decoded from a real recording.

Same bar geometry as the board's HDMI captures (first bar at x=24, 80 pixels
a bar, read over the middle 40), so a figure here predicts the board's.  The
luma order test matches scripts/video_quality.py's; on top of it this reports
what that test cannot see: how much the luma of one bar changes from line to
line, and how stable each bar's hue is, against the colours the M5 draws.

    python3 scripts/replay_quality.py build/replay.txt [--skip N] [--png OUT.png]
    python3 scripts/replay_quality.py --frames 'build/cap_*.png'

--frames scores HDMI captures from the board the same way: every other row
from 20 to 348 is one captured line, since the bob draws each line twice.
"""
import glob
import argparse
import math
import subprocess

START, WIDTH = 24, 80
# The M5 draws rgb332, so its "75%" primaries are 182 for red and green and
# 170 for blue.  Hue is what is compared, so the small level error is moot.
BARS = [(182, 182, 170), (182, 182, 0), (0, 182, 170), (0, 182, 0),
        (182, 0, 170), (182, 0, 0), (0, 0, 170), (0, 0, 0)]
NAMES = ["white", "yellow", "cyan", "green", "magenta", "red", "blue", "black"]


def uv(r, g, b):
    y = 0.299 * r + 0.587 * g + 0.114 * b
    return y, (b - y) / 2.032, (r - y) / 1.140


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?")
    ap.add_argument("--skip", type=int, default=150)
    ap.add_argument("--png")
    ap.add_argument("--frames", help="glob of captured PNG frames instead")
    a = ap.parse_args()
    recs = []
    if a.frames:
        for path in sorted(glob.glob(a.frames)):
            raw = subprocess.check_output(
                ["ffmpeg", "-v", "error", "-i", path, "-frames:v", "1",
                 "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
            if len(raw) != 640 * 480 * 3:
                continue
            for y in range(20, 350, 2):
                o = y * 640 * 3
                rgb = [tuple(raw[o+3*x:o+3*x+3]) for x in range(640)]
                recs.append(dict(idx=y, black=-1, real=1, locked=1, rgb=rgb))
        a.skip = 0
    for line in (open(a.path) if a.path else []):
        f = line.split()
        if f[0] != "L":
            continue
        px = f[6]
        if "x" in px or "z" in px:      # pixels never written: early lines
            continue
        rgb = [(int(px[i:i+2], 16), int(px[i+2:i+4], 16), int(px[i+4:i+6], 16))
               for i in range(0, 640 * 6, 6)]
        recs.append(dict(idx=int(f[1]), black=int(f[2]), real=int(f[3]),
                         locked=int(f[4]), rgb=rgb))
    body = recs[a.skip:]
    if not body:
        raise SystemExit("no lines after the warm-up")
    bars = []
    for r in body:
        row = []
        for b in range(8):
            x0 = START + b * WIDTH + 20
            cells = r["rgb"][x0:x0 + 40]
            row.append(tuple(sum(c[k] for c in cells) / 40.0 for k in range(3)))
        bars.append(row)
    ordered = sum(1 for row in bars
                  if all(uv(*row[k])[0] >= uv(*row[k+1])[0] for k in range(7)))
    print("lines scored %d (after %d warm-up), forced %d, colour-locked %d"
          % (len(body), a.skip, sum(1 for r in body if not r["real"]),
             sum(r["locked"] for r in body)))
    blacks = sorted(set(r["black"] for r in body))
    print("black reference values seen: %s" % blacks)
    print("luma in descending order: %.1f%% of lines" % (100.0 * ordered / len(bars)))
    lum0 = [uv(*row[0])[0] for row in bars]
    alt = sorted(abs(p - q) for p, q in zip(lum0, lum0[1:]))
    print("white bar luma: mean %.1f, line-to-line change median %.1f max %.1f"
          % (sum(lum0) / len(lum0), alt[len(alt)//2], alt[-1]))
    print("  bar     luma   want-hue  hue-err  line-to-line  chroma  want")
    for b in range(1, 7):
        _, U, V = uv(*BARS[b])
        want = math.degrees(math.atan2(V, U))
        errs, mags = [], []
        for row in bars:
            y, u, v = uv(*row[b])
            errs.append((math.degrees(math.atan2(v, u)) - want + 180) % 360 - 180)
            mags.append(math.hypot(u, v))
        c = sum(math.cos(math.radians(e)) for e in errs) / len(errs)
        s = sum(math.sin(math.radians(e)) for e in errs) / len(errs)
        mean_err = math.degrees(math.atan2(s, c))
        steps = sorted(abs((p - q + 180) % 360 - 180) for p, q in zip(errs, errs[1:]))
        lum = sum(uv(*row[b])[0] for row in bars) / len(bars)
        print("  %-7s %5.1f  %7.1f  %+7.1f  %6.1f med     %5.1f  %5.1f"
              % (NAMES[b], lum, want, mean_err, steps[len(steps)//2],
                 sum(mags) / len(mags), math.hypot(U, V)))
    if a.png:
        ppm = a.png + ".ppm"
        with open(ppm, "wb") as f:
            rows = [r["rgb"] for r in body[:240]]
            f.write(b"P6 640 %d 255\n" % (2 * len(rows)))
            for row in rows:
                data = bytes(v for p in row for v in p)
                f.write(data)
                f.write(data)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", ppm, a.png], check=True)
        print("wrote", a.png)


if __name__ == "__main__":
    main()
