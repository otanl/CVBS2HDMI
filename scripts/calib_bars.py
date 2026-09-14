"""Measure the decoded colour bars against their published values.

Four things this has to get right; the first three were each got wrong first and
each produced a confident, stable, wrong answer:

  * reject frames where the HDMI link has dropped -- it does, several times an
    hour, and a black frame reads as fully saturated in HSV;
  * find the bars rather than assume them -- the picture's left edge and width
    move with ACTIVE_START and the capture window;
  * never average RGB across anything the hue varies over.  The hue here wobbles
    by 20-odd degrees line to line, so averaging colours down a column, or
    across frames, pulls every bar towards grey: measured, that reported
    saturations of 0.03..0.13 for bars that are plainly 0.6..0.75 in any single
    row.  Average the hue as an angle, weighted by saturation.
  * fit the bars on luma, which does not cancel, rather than on colour.
"""
import glob, colorsys, statistics, sys, math
from PIL import Image

ROWS   = range(150, 410, 3)        # inside the bars: clear of the overlays above
                                   # and the grey ramp below
EXPECT = [("white75", None), ("yellow", 60.0), ("cyan", 180.0), ("green", 120.0),
          ("magenta", 300.0), ("red", 0.0), ("blue", 240.0), ("black", None)]

def live(px, W):
    return sum(1 for x in range(0, W, 4)
               if px[x, 4][1] > 150 and px[x, 4][0] < 100) > 10

def luma_profile(px, W):
    out = []
    for x in range(W):
        s = 0
        for y in ROWS:
            p = px[x, y]; s += p[0] + p[1] + p[2]
        out.append(s / (3.0 * len(ROWS)))
    return out

def fit_bars(prof, W):
    best = None
    for width in range(50, 110):
        for start in range(0, 60):
            if start + 8 * width > W: continue
            cost = 0.0
            for i in range(8):
                seg = prof[start + i * width + width // 4:
                           start + i * width + (3 * width) // 4]
                if len(seg) < 5: cost = 1e9; break
                m = sum(seg) / len(seg)
                cost += sum((v - m) ** 2 for v in seg) / len(seg)
            if best is None or cost < best[0]: best = (cost, start, width)
    return best

frames = sorted(glob.glob("cap*.png"))
vec, used, fit = [[0.0, 0.0, 0.0, 0.0, 0] for _ in range(8)], 0, None
for f in frames:
    im = Image.open(f).convert('RGB'); W, H = im.size; px = im.load()
    if not live(px, W): continue
    if fit is None:
        fit = fit_bars(luma_profile(px, W), W)
        if fit is None: continue
        print("bars fitted on luma: start=%d width=%d (residual %.0f)" % (fit[1], fit[2], fit[0]))
    _, start, width = fit
    for i in range(8):
        x0 = start + i * width + width // 4
        x1 = start + i * width + (3 * width) // 4
        for y in ROWS:                       # one hue per row: within a row it is constant
            r = g = b = 0
            for x in range(x0, x1, 2):
                p = px[x, y]; r += p[0]; g += p[1]; b += p[2]
            n = len(range(x0, x1, 2))
            h, sa, v = colorsys.rgb_to_hsv(r / n / 255, g / n / 255, b / n / 255)
            a = h * 2 * math.pi
            vec[i][0] += sa * math.cos(a); vec[i][1] += sa * math.sin(a)
            vec[i][2] += sa; vec[i][3] += v; vec[i][4] += 1
    used += 1

if used == 0: print("no live frames"); sys.exit(1)
print("averaged over %d live frames of %d\n" % (used, len(frames)))
print("  %-8s %-12s %-28s %s" % ("bar", "expected", "measured", ""))
rots, mirrors = [], []
for i, (name, eh) in enumerate(EXPECT):
    cx, cy, sat, val, n = vec[i]
    cx, cy, sat, val = cx / n, cy / n, sat / n, val / n
    coh = math.hypot(cx, cy) / max(sat, 1e-9)
    hue = math.degrees(math.atan2(cy, cx)) % 360
    if eh is None or sat < 0.15 or val < 0.10:
        print("  %-8s %-12s sat %.2f val %.2f coherence %.2f   (not used)"
              % (name, "achromatic" if eh is None else "hue %.0f" % eh, sat, val, coh))
        continue
    rots.append((hue - eh) % 360); mirrors.append((hue + eh) % 360)
    print("  %-8s hue %-8.0f sat %.2f val %.2f coherence %.2f   measured hue %5.0f"
          % (name, eh, sat, val, coh, hue))

def spread(v):
    return min(max((x - o) % 360 for x in v) for o in v)

if len(rots) >= 3:
    sr, sm = spread(rots), spread(mirrors)
    print("\n  as a rotation : spread %5.1f deg  (median %+.0f)" % (sr, statistics.median(rots)))
    print("  as a mirror   : spread %5.1f deg  (median %+.0f)" % (sm, statistics.median(mirrors)))
    print("\n  -> %s" % ("MIRROR, then rotate by %.0f deg" % statistics.median(mirrors)
                         if sm < sr else "rotate by %.0f deg" % statistics.median(rots)))
