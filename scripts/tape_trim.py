#!/usr/bin/env python3
"""Cut a TAPE recording to a whole, even number of lines for looped replay.

The recording starts wherever the trigger fell and is 32768 samples long, so
looping it as-is puts a broken line and a jump in the subcarrier at every seam.
This finds genuine horizontal sync edges -- a long run below the midpoint of
sync and blanking, with a flat front porch before it, so the M5's blue bar
(which sits near sync-tip level) is not mistaken for one -- and keeps an even
number of lines, starting a little before an edge.  An even count keeps the
subcarrier continuous across the seam (227.5 cycles a line) and keeps any
line-alternating property of the source in step.

    python3 scripts/tape_trim.py IN.hex OUT.hex [LINES]
"""
import sys


def sync_edges(s, blank, tip):
    mid = (blank + tip) / 2.0
    edges, n = [], 30
    while n < len(s) - 120:
        if (s[n] < mid <= s[n-1] and all(v < mid for v in s[n:n+90])
                and abs(sum(s[n-25:n-5]) / 20.0 - blank) < 3):
            edges.append(n)
            n += 1400
        else:
            n += 1
    return edges


def main():
    src, dst = sys.argv[1], sys.argv[2]
    want = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    s = [int(line, 16) for line in open(src) if line.strip()]
    ordered = sorted(s)
    tip = ordered[len(s) // 200]                      # near the bottom
    # blanking: the most common value in the upper part of the lower half
    counts = {}
    for v in s:
        if tip + 15 < v < tip + 60:
            counts[v] = counts.get(v, 0) + 1
    blank = max(counts, key=counts.get)
    edges = sync_edges(s, blank, tip)
    periods = [b - a for a, b in zip(edges, edges[1:]) if b - a < 1700]
    period = (edges[-1] - edges[0]) / round((edges[-1] - edges[0]) / 1601.6)
    span = len(edges) - 1 if not want else want
    span -= span % 2
    first = edges[0]
    last = first + round(span * period)
    lead = 40
    out = s[first - lead:last - lead]
    with open(dst, "w") as f:
        for v in out:
            f.write("%02x\n" % v)
    print("tip %d, blanking %d, %d sync edges, line period %.2f samples"
          % (tip, blank, len(edges), period))
    print("kept %d lines = %d samples (seam error %.2f samples)"
          % (span, len(out), abs(span * period - len(out))))


if __name__ == "__main__":
    main()
