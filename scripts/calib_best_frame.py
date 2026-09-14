"""Measure one good frame, not an average of all of them.

Frames right after programming, and frames where the HDMI link glitched, carry
a picture that is locked but wrong.  Averaging them in destroys the answer --
the circular mean of a rotating hue is noise, and it reports coherence near
zero whatever the good frames say.  Pick the frame with the most genuinely
saturated picture and measure that.
"""
import glob, colorsys, math, statistics, sys
from PIL import Image
EXP=[("white75",None),("yellow",60.0),("cyan",180.0),("green",120.0),
     ("magenta",300.0),("red",0.0),("blue",240.0),("black",None)]
best=None
for f in sorted(glob.glob("cap*.png")):
    im=Image.open(f).convert('RGB'); px=im.load()
    if sum(1 for x in range(0,640,4) if px[x,4][1]>150 and px[x,4][0]<100) <= 10: continue
    n=0
    for x in range(200,500,10):
        for y in range(200,400,10):
            r,g,b=px[x,y]
            h,s,v=colorsys.rgb_to_hsv(r/255,g/255,b/255)
            if v>0.2 and s>0.3: n+=1
    if best is None or n>best[0]: best=(n,f)
if best is None: print("no live frames"); sys.exit(1)
print("%s (%d saturated samples)"%(best[1],best[0]))
im=Image.open(best[1]).convert('RGB'); px=im.load()
start,width=16,80
rots=[];mirs=[]
for i,(name,eh) in enumerate(EXP):
    x0,x1=start+i*width+20, start+i*width+60
    cx=cy=ss=vv=0.0; n=0
    for y in range(150,410,2):
        r=g=b=m=0
        for x in range(x0,x1,2):
            p=px[x,y]; r+=p[0]; g+=p[1]; b+=p[2]; m+=1
        h,s,v=colorsys.rgb_to_hsv(r/m/255,g/m/255,b/m/255)
        a=h*2*math.pi; cx+=s*math.cos(a); cy+=s*math.sin(a); ss+=s; vv+=v; n+=1
    cx/=n; cy/=n; ss/=n; vv/=n
    coh=math.hypot(cx,cy)/max(ss,1e-9); hue=math.degrees(math.atan2(cy,cx))%360
    if eh is None or ss<0.15 or vv<0.10:
        print("  %-8s sat %.2f val %.2f coh %.2f  (not used)"%(name,ss,vv,coh)); continue
    rots.append((hue-eh)%360); mirs.append((hue+eh)%360)
    print("  %-8s expected %5.0f  measured %5.0f  sat %.2f coherence %.2f   diff %+6.0f"
          %(name,eh,hue,ss,coh,((hue-eh+180)%360)-180))
def spread(v): return min(max((x-o)%360 for x in v) for o in v)
if len(rots)>=3:
    print("\n  as a rotation : spread %5.1f  median %+.0f"%(spread(rots),statistics.median(rots)))
    print("  as a mirror   : spread %5.1f  median %+.0f"%(spread(mirs),statistics.median(mirs)))
