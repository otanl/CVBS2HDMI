#!/usr/bin/env python3
"""Decode captured AD9280 samples: NTSC levels, colour burst, and colour bars.

Everything is located by searching the waveform rather than by assuming fixed
offsets.  A dump starts wherever the hardware slicer thought a sync edge was,
which on a marginal source is not always a real one, so fixed windows silently
measure the wrong thing -- that mistake cost real time during bring-up.

Usage: analyse_ntsc.py <capture.txt> [dump-length]
"""
import math
import statistics as st
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_dump import dumps                                  # noqa: E402

FSC, FS = 3579545.0, 27e6
W = 2 * math.pi * FSC / FS
SC_SAMPLES = FS / FSC                       # 7.543 samples per subcarrier cycle


def boxcar(x, n):
    out, s = [], 0
    for i, v in enumerate(x):
        s += v
        if i >= n:
            s -= x[i - n]
        out.append(s / min(i + 1, n))
    return out


def luma(v):
    """Chroma-suppressed copy: the same two-stage filter the FPGA slicer uses."""
    return boxcar(boxcar(v, 8), 8)


def chroma_pp(v, k, n=16):
    w = v[k:k + n]
    return max(w) - min(w) if w else 0


def find_sync(lp):
    """The longest run at the filtered signal's floor is the sync pulse."""
    lo, hi = min(lp), max(lp)
    thr = lo + (hi - lo) * 0.25
    runs, start = [], None
    for i, s in enumerate(lp):
        if s < thr and start is None:
            start = i
        elif s >= thr and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(lp)))
    return max(runs, key=lambda r: r[1] - r[0]) if runs else None


def find_burst(v, after):
    """The colour burst: a chroma packet right after the sync pulse.

    The search stops 200 samples (7.4 us) past the sync pulse.  NTSC puts the
    burst 0.6 us after sync ends, so anything further away is picture content,
    and accepting it produced burst references 13 us out of place and garbage
    hue readings.
    """
    start = None
    for k in range(after, min(after + 200, len(v) - 16), 4):
        pp = chroma_pp(v, k)
        if pp > 15 and start is None:
            start = k
        elif pp <= 10 and start is not None:
            if k - start >= 32:
                return start, k
            start = None
    return None


def analyse(v, label, verbose=True):
    lp = luma(v)
    sync = find_sync(lp)
    if not sync:
        return None
    s0, s1 = sync
    sync_level = st.median(lp[s0:s1])
    burst = find_burst(v, s1)
    if not burst:
        if verbose:
            print(f"[{label}] sync {s0}..{s1}, no burst found")
        return None
    b0, b1 = burst
    seg = v[b0:b1]
    dc = st.mean(seg)
    I = sum((s - dc) * math.cos(W * (b0 + k)) for k, s in enumerate(seg))
    Q = sum((s - dc) * math.sin(W * (b0 + k)) for k, s in enumerate(seg))
    bamp = 2 * math.hypot(I, Q) / len(seg)
    ref = math.atan2(Q, I) - math.pi            # NTSC burst sits on -U
    blank = st.median(lp[b1 + 8:b1 + 56])
    if verbose:
        print(f"[{label}] sync {s0}..{s1} ({(s1-s0)/FS*1e6:5.2f} us, NTSC 4.70) "
              f"level {sync_level:5.1f} | burst {b0}..{b1} "
              f"({(b1-b0)/SC_SAMPLES:4.1f} cycles, NTSC 9.0) amp {bamp:5.1f} | "
              f"blank {blank:5.1f} sync-to-blank {blank-sync_level:5.1f}")
    return dict(blank=blank, ref=ref, bamp=bamp, active=b1 + 60,
                sync_level=sync_level, white=max(lp))


BARS = [("white75", 191, 191, 191), ("yellow", 191, 191, 0),
        ("cyan", 0, 191, 191), ("green", 0, 191, 0),
        ("magenta", 191, 0, 191), ("red", 191, 0, 0),
        ("blue", 0, 0, 191), ("black", 0, 0, 0)]


def expect(r, g, b):
    y = 0.299 * r + 0.587 * g + 0.114 * b
    return y, 0.492 * (b - y), 0.877 * (r - y)


def decode_bars(v, info):
    blank, ref, act = info["blank"], info["ref"], info["active"]
    # Scale so the 75% white bar reads 191, matching what was encoded.
    gain = 191.0 / max(1.0, info["white"] - blank)
    n = 1440
    print(f"\nscaling: white75 at {info['white']-blank:.0f} codes above blanking "
          f"-> gain {gain:.3f}")
    print(f"{'bar':9s} {'Y':>7s} {'U':>7s} {'V':>7s} | "
          f"{'expY':>7s} {'expU':>7s} {'expV':>7s} | {'hue err':>8s} {'sat':>6s}")
    for i, (name, r, g, b) in enumerate(BARS):
        a, z = act + (n * i) // 8 + 50, act + (n * (i + 1)) // 8 - 50
        if z > len(v):
            print(f"{name:9s}   (past the end of the captured line)")
            break
        Y = U = V = 0.0
        for k in range(a, z):
            s = (v[k] - blank) * gain
            ang = W * k - ref
            Y += s
            U += 2 * s * math.cos(ang)
            V += 2 * s * math.sin(ang)
        cnt = z - a
        Y, U, V = Y / cnt, U / cnt, V / cnt
        ey, eu, ev = expect(r, g, b)
        sm, se = math.hypot(U, V), math.hypot(eu, ev)
        if sm > 5 and se > 5:
            he = ((math.degrees(math.atan2(V, U) - math.atan2(ev, eu)) + 180) % 360) - 180
            herr, ratio = f"{he:8.1f}", f"{sm/se:6.2f}"
        else:
            herr, ratio = "       -", "     -"
        print(f"{name:9s} {Y:7.1f} {U:7.1f} {V:7.1f} | "
              f"{ey:7.1f} {eu:7.1f} {ev:7.1f} | {herr} {ratio}")


if __name__ == "__main__":
    ds = dumps(open(sys.argv[1]).read(),
               int(sys.argv[2]) if len(sys.argv) > 2 else None)
    print(f"{len(ds)} dump(s) of {len(ds[0]) if ds else 0} samples\n")
    best = None
    for i, v in enumerate(ds):
        info = analyse(v, f"dump{i:2d}")
        if not info:
            continue
        end = min(info["active"] + 1200, len(v) - 16)
        energy = st.mean([chroma_pp(v, k) for k in range(info["active"], end, 16)]) \
            if end > info["active"] else 0
        if best is None or energy > best[0]:
            best = (energy, v, info)
    if best:
        print(f"\n=== most colourful line (mean chroma {best[0]:.0f} codes p-p) ===")
        decode_bars(best[1], best[2])
