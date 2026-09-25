#!/usr/bin/env python3
"""Recover AD9280 levels from the existing HDMI oscilloscope trace.

What this measures well is GEOMETRY -- where sync, burst, back porch and the
bars are, and how long each lasts.  Checked against a real capture, the line
comes back as 190 samples of flat, 72 of burst, 48 of back porch and then the
bars, which is 7.5 / 2.9 / 1.9 us against NTSC's 6.8 / 2.5 / 1.6, and the next
line's burst lands 1593 samples after this one's against a 1597-sample line.

What it does NOT measure reliably is AMPLITUDE inside a fast oscillation.  The
burst comes back as three discrete levels -- 18, 34 and 130 -- where a sinusoid
sampled every third sample (153 degrees a column) has to spread around the
circle.  The hardware's own min/max detector reads 19 codes across the same
window.  Until that factor of five is explained, read levels from flat regions
only and treat a burst amplitude from here as unconfirmed.

The full-range display plots y = 479 - ADC, with a seven-pixel-thick
red/white trace. Its horizontal scale is three ADC samples per pixel.
Recover amplitude from POSITION, not RGB intensity after HDMI conversion.
Ambiguous columns (e.g. a snapshot changing during scanout) are rejected.
Requires ffmpeg/ffprobe, but no Pillow/numpy and no UART access.
"""
import argparse
import json
import math
import statistics
import subprocess


def scope_identity(data, width=640, height=480):
    """Read the full-range scope's mode/phase/frame header, or None.

    Both versions occupy y=200..207, 32 monochrome cells of 16 pixels each.
    Sample cell centres to tolerate HDMI 4:2:2 filtering and pixel latency.
    """
    if (width, height) != (640, 480) or len(data) != width*height*3:
        raise ValueError("expected a 640x480 RGB24 scope image")
    word = 0
    for cell in range(32):
        levels = [data[(y*width+x)*3] for y in range(202, 206)
                  for x in range(cell*16+6, cell*16+10)]
        level = statistics.median(levels)
        if 70 < level < 180:
            return None
        word = (word << 1) | (level >= 180)
    if word >> 24 != 0xA5:
        return None
    if word & 0xFF == 1 and not word & (1 << 16):
        # Version 1: a three-bit read phase of five, then a reserved zero.
        return dict(mode=(word >> 20) & 15, phase=(word >> 17) & 7,
                    frame=(word >> 8) & 255, version=1)
    if word & 0xFF == 2:
        # Version 2: the converter clock's rotation, four bits, 0..9.
        return dict(mode=(word >> 20) & 15, phase=(word >> 16) & 15,
                    frame=(word >> 8) & 255, version=2)
    return None


def extract_trace(data, width=640, height=480, legacy_scale=False):
    if (width, height) != (640, 480) or len(data) != width*height*3:
        raise ValueError("expected a 640x480 RGB24 scope image")
    values = []
    for x in range(width):
        runs, run = [], []
        # The coloured diagnostic bars occupy y < 192. Legacy scaling hides
        # high ADC codes there; full range places every code at y >= 224.
        for y in range(196 if legacy_scale else 216, height):
            k = (y*width+x)*3
            r, g, b = data[k:k+3]
            # The trace is white above the slicing threshold and red below
            # it, and the threshold line itself is green (r = 0), so red alone
            # separates them.  The level matters: a mark is one column wide, and
            # where neighbouring columns sit at very different heights -- which
            # is exactly the strongly modulated part worth measuring -- the
            # capture card's horizontal filtering dims it.  At r > 180 those
            # columns vanish entirely; at r > 120 they come back.  Validated
            # against the stricter test: recovery goes from 551 to 639 of 640
            # columns, and where both read a column they differ by at most 2.
            is_trace = r > 120
            if is_trace:
                run.append(y)
            elif run:
                runs.append(run)
                run = []
        if run:
            runs.append(run)
        # A dimmed mark survives as a shorter run; 11 still rejects two merged.
        runs = [r for r in runs if 2 <= len(r) <= 11]
        if len(runs) == 1:
            y = statistics.mean(runs[0])
            # Codes 0..2 clip the bottom half of the seven-pixel mark.
            # The remaining top edge still identifies its centre exactly.
            if runs[0][-1] == height-1 and len(runs[0]) < 7:
                y = runs[0][0] + 3
            values.append(round((479-y)*(8/15 if legacy_scale else 1)))
        else:
            values.append(None)
    return values


def locate_burst(values, tol=3, min_flat=8):
    """Find the colour burst by structure: an oscillating stretch between two
    flat ones, at the blanking level.

    Fixed offsets do not work here.  About half the lines start from the
    flywheel rather than from a detected sync, so the dump can begin anywhere
    in the line, and the geometry slides with it.  Searching for the shape
    instead costs nothing and cannot be aimed at the wrong place -- which
    assuming offsets did: measuring 103..40 samples before the first bright bar
    landed on the *previous* line's back porch and reported a flat 0.1 codes,
    which reads as "this source has no burst" and is wrong by a factor of six.

    Returns (start_col, end_col) inclusive, or None.
    """
    known = [v for v in values if v is not None]
    if len(known) < 300:
        return None
    floor = min(statistics.multimode([v for v in known if v < min(known)+40]))

    # Flatness has to be judged over a neighbourhood, not per column.  A
    # sinusoid sampled every third sample crosses its own mean, so single
    # columns inside the burst sit at exactly the blanking level and split the
    # run into pieces too short to recognise.
    def flat_at(c):
        seg = [v for v in values[max(0, c-4):c+5] if v is not None]
        if len(seg) < 5 or values[c] is None:
            return False
        return abs(values[c]-floor) <= tol and max(seg)-min(seg) <= 2*tol

    flat = [flat_at(c) for c in range(len(values))]
    best = None
    n = len(values)
    c = 0
    while c < n:
        if flat[c]:
            c += 1
            continue
        s0 = c
        while c < n and not flat[c]:
            c += 1
        # 54..90 ADC samples is 2.1..3.6 us: the burst, not a picture edge.
        if not 18 <= c-s0 <= 30:
            continue
        if sum(flat[max(0, s0-min_flat):s0]) < min_flat or \
           sum(flat[c:c+min_flat]) < min_flat:
            continue
        seg = [v for v in values[s0:c] if v is not None]
        if len(seg) < 8:
            continue
        span = max(seg)-min(seg)
        if best is None or span > best[2]:
            best = (s0, c-1, span)
    return None if best is None else (best[0], best[1])


def solve3(matrix, rhs):
    a = [list(row)+[v] for row, v in zip(matrix, rhs)]
    for col in range(3):
        pivot = max(range(col, 3), key=lambda r: abs(a[r][col]))
        a[col], a[pivot] = a[pivot], a[col]
        scale = a[col][col]
        if abs(scale) < 1e-9:
            raise ValueError("insufficient independent carrier samples")
        a[col] = [v/scale for v in a[col]]
        for row in range(3):
            if row != col:
                scale = a[row][col]
                a[row] = [v-scale*w for v, w in zip(a[row], a[col])]
    return [a[row][3] for row in range(3)]


def fit_carrier(values, start, end, carrier=315e6/88, sample_rate=25.2e6):
    points = [(3*x, value) for x, value in enumerate(values)
              if value is not None and start <= 3*x < end]
    if len(points) < 8:
        raise ValueError("too few trace samples in carrier window")
    basis = [(1, math.cos(2*math.pi*carrier*x/sample_rate),
                 math.sin(2*math.pi*carrier*x/sample_rate)) for x, _ in points]
    matrix = [[sum(p[i]*p[j] for p in basis) for j in range(3)] for i in range(3)]
    rhs = [sum(p[i]*v for p, (_, v) in zip(basis, points)) for i in range(3)]
    dc, co, si = solve3(matrix, rhs)
    residual = math.sqrt(statistics.mean((v-(dc+co*p[1]+si*p[2]))**2
                        for p, (_, v) in zip(basis, points)))
    return dict(dc=dc, cosine=co, sine=si, amplitude=math.hypot(co, si),
                rms=residual, samples=len(points))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--legacy-scale", action="store_true", help="old 15/8-pixels-per-code view")
    parser.add_argument("--trace-only", action="store_true", help="report samples/identity without fitting colour")
    parser.add_argument("--require-mode", type=int, choices=range(16), help="reject a stale/wrong-mode scope image")
    parser.add_argument("--burst", default="240:300", help="ADC sample interval")
    parser.add_argument("--porch", default="305:337", help="ADC sample interval")
    parser.add_argument("--bars", type=int, default=343, help="first bar, ADC sample index")
    parser.add_argument("--bar-width", type=int, default=160, help="ADC samples per bar")
    parser.add_argument("--luma-gain", type=float, default=45/16)
    parser.add_argument("--chroma-gain", type=float, default=45/16)
    args = parser.parse_args()
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height", "-of", "json", args.image]))["streams"][0]
    data = subprocess.check_output(["ffmpeg", "-v", "error", "-i", args.image,
                                   "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
    values = extract_trace(data, probe["width"], probe["height"], args.legacy_scale)
    identity = scope_identity(data, probe["width"], probe["height"])
    if args.require_mode is not None and (identity is None or identity["mode"] != args.require_mode):
        parser.error("missing identity or wrong scope mode")
    if sum(v is not None for v in values) < 500:
        parser.error("not a readable scope frame (or trace outside the unobscured range)")
    if args.trace_only:
        print(json.dumps(dict(image=args.image, identity=identity,
                              valid_columns=sum(v is not None for v in values),
                              adc_trace=values), indent=2))
        return
    burst = fit_carrier(values, *map(int, args.burst.split(":")))
    porch = fit_carrier(values, *map(int, args.porch.split(":")))
    if burst["amplitude"] < 2:
        parser.error("no measurable burst in selected window")
    bc, bs = burst["cosine"]/burst["amplitude"], burst["sine"]/burst["amplitude"]
    bars = []
    for i in range(8):
        start = args.bars + args.bar_width*i
        fit = fit_carrier(values, start+30, start+args.bar_width-30)
        y = (fit["dc"]-porch["dc"])*args.luma_gain
        u = -(fit["cosine"]*bc+fit["sine"]*bs)*args.chroma_gain
        v = (fit["sine"]*bc-fit["cosine"]*bs)*args.chroma_gain
        bars.append(dict(index=i, **fit, y=y, u=u, v=v,
                         rgb=[y+1.140*v, y-0.395*u-0.581*v, y+2.032*u]))
    print(json.dumps(dict(image=args.image, identity=identity,
                         warning="Scope carrier amplitude is unvalidated; do not use this fit to calibrate gain.",
                         valid_columns=sum(v is not None for v in values),
                         burst=burst, porch=porch, bars=bars, adc_trace=values), indent=2))


if __name__ == "__main__":
    main()
