#!/usr/bin/env python3
"""Measure what an input filter change did, from two TAPE recordings.

Both recordings must come from ONE boot of the M5: its line buffers, and so its
blanking levels and even each bar's chroma, change from boot to boot, and a
comparison across a reboot measures the reboot.  Keep the M5 powered while
the Tang board is reworked.

For each recording the colour burst and every bar are fitted jointly across
all lines at the subcarrier and at the two alias products that fold next to it
at 25.2 MSPS (25.2 - 6 fsc and 8 fsc - 25.2).  Reported: the change in chroma
(what the decoder's chroma gain must make up) and in each alias product (what
the filter bought).

    python3 scripts/filter_check.py BEFORE.hex AFTER.hex
    (both trimmed with scripts/tape_trim.py)
"""
import math
import sys

import numpy as np

FS = 25.2e6
NAMES = ["white", "yellow", "cyan", "green", "magenta", "red", "blue"]


def period_of(s):
    """Line period from the sync edges, sliced just above the tip."""
    tip = sorted(s)[len(s) // 200]
    cut = tip + 8
    edges, n = [], 30
    while n < len(s) - 120:
        if s[n] < cut <= s[n-1] and all(v < cut for v in s[n:n+100]):
            edges.append(n)
            n += 100
        else:
            n += 1
    edges = [c for c in edges if any(abs(abs(d - c) - 1601.6) < 4 for d in edges if d != c)]
    return (edges[-1] - edges[0]) / round((edges[-1] - edges[0]) / 1601.6)


def fit(path):
    s = np.array([int(v, 16) for v in open(path) if v.strip()], dtype=float)
    P = period_of(list(s.astype(int)))
    fsc = 227.5 / P * FS
    freqs = [fsc, FS - 6 * fsc, 8 * fsc - FS]
    lines = int((len(s) - 40) // P) - 1
    out = {}
    regions = [("burst", 142, 48)] + [(NAMES[b], int(262 + b * 157.5) + 8, 140) for b in range(7)]
    for name, off, width in regions:
        idx, lid = [], []
        for ln in range(lines):
            a = int(40 + ln * P) + off
            idx += range(a, a + width)
            lid += [ln] * width
        n = np.array(idx)
        lid = np.array(lid)
        cols = [(lid == ln).astype(float) for ln in range(lines)]
        for f in freqs:
            w = 2 * math.pi * f / FS * n
            cols += [np.cos(w), np.sin(w)]
        c, *_ = np.linalg.lstsq(np.stack(cols, 1), s[n], rcond=None)
        out[name] = [math.hypot(c[lines + 2*i], c[lines + 2*i + 1]) for i in range(3)]
    return P, out


def db(a, b):
    return 20 * math.log10(max(a, 1e-3) / max(b, 1e-3))


def main():
    pb, before = fit(sys.argv[1])
    pa, after = fit(sys.argv[2])
    print("line period %.2f / %.2f samples" % (pb, pa))
    print("%-8s | %-24s | %-24s | %-24s" % ("", "chroma 3.58 MHz", "alias of 21.5 MHz", "alias of 28.6 MHz"))
    for name in ["burst"] + NAMES:
        b, a = before[name], after[name]
        print("%-8s | %6.1f -> %6.1f %+6.1f dB | %6.1f -> %6.1f %+6.1f dB | %6.1f -> %6.1f %+6.1f dB"
              % (name, b[0], a[0], db(a[0], b[0]), b[1], a[1], db(a[1], b[1]),
                 b[2], a[2], db(a[2], b[2])))
    strong = ["green", "magenta", "red", "blue"]
    for k, label in ((0, "chroma"), (1, "alias 21.5 MHz"), (2, "alias 28.6 MHz")):
        sb = sum(before[n][k] for n in strong)
        sa = sum(after[n][k] for n in strong)
        print("strong bars, %-15s %+6.1f dB" % (label + ":", db(sa, sb)))
    g = sum(after[n][0] for n in strong) / sum(before[n][0] for n in strong)
    print("chroma gain to restore: x%.2f" % (1 / g))


if __name__ == "__main__":
    main()
