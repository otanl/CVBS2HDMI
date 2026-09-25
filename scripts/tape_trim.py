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
    """Sync leading edges: a run of 100+ samples just above the sync tip, with
    another such run one line away.  The M5 can hold its
    black bar near sync-tip level on alternate lines, which makes a
    sync-length pulse too, but only every other line -- so it has no partner
    a line away and drops out.  The porches are not used: the M5 leaves them
    at different levels from one boot to the next."""
    # Just above the tip, not halfway to blanking: the M5 parks some porches at
    # the burst's low level, 98..101, which a midpoint slice would catch.
    mid = tip + 8
    cands, n = [], 30
    while n < len(s) - 120:
        if s[n] < mid <= s[n-1] and all(v < mid for v in s[n:n+100]):
            cands.append(n)
            n += 100
        else:
            n += 1
    line = 1601.6
    return [c for c in cands
            if any(abs(abs(d - c) - line) < 4 for d in cands if d != c)]


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
    blank = max(counts, key=counts.get)   # only sets the slicing midpoint
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
