#!/usr/bin/env python3
"""Floating-point reference decode of a TAPE recording's colour bars.

What the decoder should produce for this particular signal, as opposed to what
a textbook bar would give -- the two differ when the source is imperfect, and a
decoder can only be judged against the first.  Per line: the sync leading edge
to a fraction of a sample, the burst's phase by correlation at the source's own
subcarrier frequency (227.5 cycles per measured line), and each bar's luma
above blanking and chroma vector relative to that burst.  Levels are scaled by
the sync height, which NTSC fixes at 40 IRE.

    python3 scripts/tape_reference.py sim/m5_tape_18lines.hex
"""
import cmath
import math
import sys

BAR0, BARW = 262, 157.5            # first bar and pitch, samples from sync edge
NAMES = ["white", "yellow", "cyan", "green", "magenta", "red", "blue", "black"]
WANT = [None, 167.1, -79.0, -119.3, 63.5, 103.5, -12.9, None]


def main():
    s = [int(v, 16) for v in open(sys.argv[1]) if v.strip()]
    tip = sorted(s)[len(s) // 200]
    mid = (tip + 117) / 2.0
    edges, n = [], 30
    while n < len(s) - 1700:
        if s[n] < mid <= s[n-1] and all(v < mid for v in s[n:n+90]) \
                and abs(sum(s[n-25:n-5]) / 20.0 - 117) < 3:
            edges.append(n - 1 + (s[n-1] - mid) / (s[n-1] - s[n]))
            n += 1400
        else:
            n += 1
    period = (edges[-1] - edges[0]) / round((edges[-1] - edges[0]) / 1601.6)
    f = 227.5 / period
    print("lines %d  period %.3f  subcarrier %.6f MHz"
          % (len(edges), period, f * 25.2))
    acc = [[] for _ in range(8)]
    for e in edges:
        e0 = int(e)
        fp = sum(s[e0-30:e0-8]) / 22.0
        tipl = sum(s[e0+20:e0+100]) / 80.0
        ire = 40.0 / (fp - tipl)
        b = sum((s[k] - fp) * cmath.exp(-2j * math.pi * f * k)
                for k in range(e0 + 140, e0 + 190))
        for bar in range(8):
            lo = int(e + BAR0 + bar * BARW + 30)
            hi = int(lo + 7.04 * 12)        # twelve whole cycles
            seg = s[lo:hi]
            y = (sum(seg) / len(seg) - fp) * ire
            c = sum((v - fp) * cmath.exp(-2j * math.pi * f * k)
                    for k, v in zip(range(lo, hi), seg))
            amp = 2 * abs(c) / len(seg) * ire
            # chroma relative to the burst, which sits at 180 degrees (-U)
            ang = math.degrees(cmath.phase(c) - cmath.phase(b)) + 180
            acc[bar].append((y, amp, (ang + 180) % 360 - 180))
    print("  bar      luma IRE  chroma IRE  hue   (textbook 75%%: hue, amplitude)")
    for bar in range(8):
        ys = [a[0] for a in acc[bar]]
        am = [a[1] for a in acc[bar]]
        cs = sum(math.cos(math.radians(a[2])) for a in acc[bar])
        sn = sum(math.sin(math.radians(a[2])) for a in acc[bar])
        hue = math.degrees(math.atan2(sn, cs))
        spread = max(abs((a[2] - hue + 180) % 360 - 180) for a in acc[bar])
        print("  %-8s %6.1f    %6.1f    %+6.1f (+-%.1f)  %s"
              % (NAMES[bar], sum(ys) / len(ys), sum(am) / len(am), hue, spread,
                 "" if WANT[bar] is None else "%+.1f" % WANT[bar]))


if __name__ == "__main__":
    main()
