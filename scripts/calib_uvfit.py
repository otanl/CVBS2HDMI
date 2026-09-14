"""Fit the decoder's chroma transform in the UV plane, not in hue.

Hue is the wrong space to measure this in.  The YUV to RGB matrix is not a
rotation -- R takes 1.140 V and B takes 2.032 U -- so the chroma plane is
anisotropically scaled on its way to RGB.  A given phase wobble therefore
produces a hue wobble whose size depends on *where in the plane* the colour
sits, which means:

  * a constant rotation changes the measured hue coherence, even though it
    cannot change anything about the phase stability;
  * a "median hue error" is not the rotation, and two captures can disagree by
    60 degrees without anything having changed.

Both of those were observed and neither is mysterious once the space is right.

RGB comes back to UV exactly, because the decoder's matrix is the standard one
and its inverse is the standard luma sum:

    Y = 0.299 R + 0.587 G + 0.114 B
    v = (R - Y) / 1.140        u = (B - Y) / 2.032

With (u,v) measured and (U,V) known for each bar, a 2x2 least-squares fit gives
the whole transform in one step -- and the sign of its determinant answers the
mirror question outright instead of by comparing spreads.
"""
import glob, math, sys
from PIL import Image

# 75% bars, BT.601: U = 0.492(B-Y), V = 0.877(R-Y), components 191 or 0.
def uv_of(r, g, b):
    y = 0.299 * r + 0.587 * g + 0.114 * b
    return 0.492 * (b - y), 0.877 * (r - y)

BARS = [("white75", 191, 191, 191), ("yellow", 191, 191, 0), ("cyan", 0, 191, 191),
        ("green", 0, 191, 0), ("magenta", 191, 0, 191), ("red", 191, 0, 0),
        ("blue", 0, 0, 191), ("black", 0, 0, 0)]

def decode_uv(r, g, b):
    """Invert the decoder's own matrix to recover what it demodulated."""
    y = 0.299 * r + 0.587 * g + 0.114 * b
    return (b - y) / 2.032, (r - y) / 1.140

def live(px, W):
    return sum(1 for x in range(0, W, 4)
               if px[x, 4][1] > 150 and px[x, 4][0] < 100) > 10

frames = [f for f in sorted(glob.glob("cap*.png"))]
best = None
for f in frames:
    im = Image.open(f).convert('RGB'); W, H = im.size; px = im.load()
    if not live(px, W): continue
    n = 0
    for x in range(200, 500, 10):
        for y in range(200, 400, 10):
            r, g, b = px[x, y]
            if max(r, g, b) - min(r, g, b) > 60 and 30 < max(r, g, b) < 250: n += 1
    if best is None or n > best[0]: best = (n, f)
if best is None: print("no live frames"); sys.exit(1)
print("%s (%d chromatic samples)\n" % (best[1], best[0]))
im = Image.open(best[1]).convert('RGB'); px = im.load()

START, WIDTH = 16, 80
rows = range(150, 410, 2)
meas, want, names = [], [], []
print("  %-8s %-22s %-22s %s" % ("bar", "expected U,V", "decoded u,v (mean)", "coherence"))
for i, (name, er, eg, eb) in enumerate(BARS):
    U, V = uv_of(er, eg, eb)
    if math.hypot(U, V) < 5: 
        print("  %-8s achromatic, skipped" % name); continue
    x0, x1 = START + i * WIDTH + 20, START + i * WIDTH + 60
    su = sv = 0.0; sm = 0.0; k = 0
    for y in rows:
        r = g = b = m = 0
        clipped = False
        for x in range(x0, x1, 2):
            p = px[x, y]
            if max(p) >= 253 or min(p) <= 1: clipped = True
            r += p[0]; g += p[1]; b += p[2]; m += 1
        if clipped: continue
        u, v = decode_uv(r / m, g / m, b / m)
        su += u; sv += v; sm += math.hypot(u, v); k += 1
    if k < 20:
        print("  %-8s too few unclipped rows (%d)" % (name, k)); continue
    su /= k; sv /= k; sm /= k
    coh = math.hypot(su, sv) / max(sm, 1e-9)
    meas.append((su, sv)); want.append((U, V)); names.append(name)
    print("  %-8s (%7.1f,%7.1f)      (%7.1f,%7.1f)        %.2f" % (name, U, V, su, sv, coh))

if len(meas) < 3: print("\nnot enough bars"); sys.exit(1)

# least squares for M with [u v]^T = M [U V]^T
sxx = sum(U * U + V * V for U, V in want)
a = sum(u * U + v * V for (u, v), (U, V) in zip(meas, want)) / sxx   # cos-like
b_ = sum(v * U - u * V for (u, v), (U, V) in zip(meas, want)) / sxx  # sin-like
c  = sum(u * U - v * V for (u, v), (U, V) in zip(meas, want)) / sxx  # mirror cos
d  = sum(v * U + u * V for (u, v), (U, V) in zip(meas, want)) / sxx  # mirror sin

rot_gain = math.hypot(a, b_);  rot_ang = math.degrees(math.atan2(b_, a)) % 360
mir_gain = math.hypot(c, d);   mir_ang = math.degrees(math.atan2(d, c)) % 360

def resid(kind):
    tot = 0.0
    for (u, v), (U, V) in zip(meas, want):
        if kind == 'rot': pu, pv = a * U - b_ * V, b_ * U + a * V
        else:             pu, pv = c * U + d * V, d * U - c * V
        tot += (u - pu) ** 2 + (v - pv) ** 2
    return math.sqrt(tot / len(meas))

print("\n  rotation fit : gain %.3f  angle %6.1f deg   rms residual %6.1f" % (rot_gain, rot_ang, resid('rot')))
print("  mirror  fit  : gain %.3f  angle %6.1f deg   rms residual %6.1f" % (mir_gain, mir_ang, resid('mir')))
print("\n  -> %s" % ("MIRROR + rotate %.0f deg" % mir_ang if resid('mir') < resid('rot')
                     else "rotate %.0f deg" % rot_ang))
