#!/usr/bin/env python3
"""Recover the recorded ADC samples from TAPE-mode HDMI frames.

`make ntsc-tape-program` records 32768 consecutive samples once and shows them
as grey cells: rows 0-7 carry 32 identity bits (16 px each, 0xA55A, a
recording-complete flag, a frame counter), rows 8-15 a calibration staircase of
the sixteen grey levels, and rows 16-425 the samples, 80 a row, each as two
4-pixel cells -- high nibble, then low -- with grey = 16 + 14 * nibble, inside
video's limited range so a card that expands 16..235 keeps them distinct.

Levels are learned from the calibration rows of every frame rather than
assumed, so a capture card that maps RGB to limited range, or shifts the
levels a little, still decodes exactly.  Each cell is read at its two centre
pixels, away from the horizontal filtering that blurs cell edges.  Frames
are voted per sample, and a frame whose header is wrong, whose recording is
not complete, or whose levels are not cleanly separated is rejected rather
than trusted.

    python3 scripts/tape_decode.py OUT.hex FRAME.png [FRAME.png ...]
"""
import subprocess
import sys
from collections import Counter

W, H = 640, 480
ROW0, ROWS, PER_ROW, SAMPLES = 16, 410, 80, 32768
MAGIC = 0xA55A


def load(path):
    """Return the frame as rows of luma (mean of R, G and B)."""
    if path.endswith((".ppm", ".pgm")):
        tokens = open(path).read().split()
        assert tokens[0] == "P2" and tokens[1:3] == ["640", "480"], path
        values = [int(t) for t in tokens[4:]]
        return [values[y*W:(y+1)*W] for y in range(H)]
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-i", path, "-frames:v", "1",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
    if len(raw) != W*H*3:
        raise ValueError("%s is not a 640x480 frame" % path)
    return [[(raw[(y*W+x)*3] + raw[(y*W+x)*3+1] + raw[(y*W+x)*3+2]) / 3.0
             for x in range(W)] for y in range(H)]


def header(lum):
    bits = 0
    for k in range(32):
        bits = (bits << 1) | (1 if lum[4][16*k + 8] > 127 else 0)
    return bits


def levels(lum):
    """Median grey of each nibble, from the calibration rows."""
    seen = [[] for _ in range(16)]
    for y in range(9, 15):
        for cell in range(160):
            seen[cell % 16] += [lum[y][4*cell + 1], lum[y][4*cell + 2]]
    return [sorted(v)[len(v)//2] for v in seen]


def decode(lum, lev):
    """Samples, and the smallest decision margin met while reading them."""
    def nibble(y, x):
        v = (lum[y][x+1] + lum[y][x+2]) / 2.0
        d = sorted((abs(v - lev[n]), n) for n in range(16))
        return d[0][1], d[1][0] - d[0][0]
    out, worst = [], 1e9
    for i in range(SAMPLES):
        y, s = ROW0 + i // PER_ROW, i % PER_ROW
        hi, m1 = nibble(y, 8*s)
        lo, m2 = nibble(y, 8*s + 4)
        worst = min(worst, m1, m2)
        out.append(hi*16 + lo)
    return out, worst


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out_path, frames = sys.argv[1], sys.argv[2:]
    decoded, rejected = [], Counter()
    for path in frames:
        lum = load(path)
        h = header(lum)
        if h >> 16 != MAGIC:
            rejected["no tape header"] += 1
            continue
        if not (h >> 8) & 1:
            rejected["recording not complete"] += 1
            continue
        lev = levels(lum)
        gaps = [b - a for a, b in zip(lev, lev[1:])]
        if min(gaps) < 6:
            rejected["grey levels not separated"] += 1
            continue
        samples, margin = decode(lum, lev)
        decoded.append((samples, margin, lev))
    if not decoded:
        raise SystemExit("no usable tape frames: %s" % dict(rejected))
    voted, disputed = [], 0
    for i in range(SAMPLES):
        votes = Counter(d[0][i] for d in decoded)
        value, n = votes.most_common(1)[0]
        if n != len(decoded):
            disputed += 1
        voted.append(value)
    with open(out_path, "w") as f:
        for v in voted:
            f.write("%02x\n" % v)
    lev = decoded[0][2]
    print("frames used %d of %d%s" % (len(decoded), len(frames),
          ("  rejected: %s" % dict(rejected)) if rejected else ""))
    print("grey levels %s" % " ".join("%.0f" % v for v in lev))
    print("worst decision margin %.1f grey codes (levels ~%.0f apart)"
          % (min(d[1] for d in decoded), (lev[15]-lev[0])/15))
    print("samples where frames disagree: %d of %d" % (disputed, SAMPLES))
    print("wrote %s: %d samples, min %d max %d"
          % (out_path, SAMPLES, min(voted), max(voted)))


if __name__ == "__main__":
    main()
