#!/usr/bin/env python3
"""Re-derive layers/*.png from condenser-detail.gif.

Documents the derivation described in README.md. Requires Pillow + numpy.
Run from this directory:  python3 derive_layers.py
Every constant below is either measured (see README "The native grid") or an
explicitly reconstructed choice (see README "What is solid and what is not").
"""
import numpy as np, os, json
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
LAY = os.path.join(HERE, 'layers')
os.makedirs(LAY, exist_ok=True)

_gif = Image.open(os.path.join(HERE, 'condenser-detail.gif'))
_fr = []
for i in range(_gif.n_frames):
    _gif.seek(i); _fr.append(np.array(_gif.convert('RGB')).astype(np.float32))
F = np.stack(_fr)
# --- measured grid (README: "The native grid") ---
CELL = 6          # measured block size of the animated overlay
OX, OY = 2, 0     # detail-px origin of the grid-aligned overlay canvas
NW, NH = 103, 55  # native canvas, cells

MED=np.median(F,axis=0)
TSTD=F.std(axis=0).sum(axis=2)

def nat(img,agg=np.median):
    s=img[OY:OY+NH*CELL, OX:OX+NW*CELL]
    if s.ndim==3: return agg(s.reshape(NH,CELL,NW,CELL,3),axis=(1,3))
    return agg(s.reshape(NH,CELL,NW,CELL),axis=(1,3))

PLATE=nat(MED)                       # 55x103x3 static native plate
STD  =nat(TSTD, np.mean)             # 55x103 temporal activity

WIN =dict(x0=4,x1=97,y0=3,y1=54)
RES =dict(x0=4,x1=97,y0=48,y1=54)
COOL=dict(x0=17,x1=31,y0=32,y1=55)
OCC =(19,30)
MISTB=(28,48)

X,Y=np.meshgrid(np.arange(NW),np.arange(NH))
inwin =(X>=WIN['x0'])&(X<WIN['x1'])&(Y>=WIN['y0'])&(Y<WIN['y1'])
inres =(X>=RES['x0'])&(X<RES['x1'])&(Y>=RES['y0'])&(Y<RES['y1'])
incool=(X>=COOL['x0'])&(X<COOL['x1'])&(Y>=COOL['y0'])&(Y<COOL['y1'])

# ---------- mist: unmix a light haze from the plate over the mist band ----------
MIST_RGB=np.array([173.,202.,198.])          # measured drop-head / haze highlight tone
lum=PLATE.mean(axis=2)
band=np.zeros((NH,NW),bool); band[MISTB[0]:MISTB[1],:]=True
band&=inwin
floor=np.percentile(lum[band],8)
lift=np.clip((lum-floor)/(np.percentile(lum[band],98)-floor),0,1)
act =np.clip(STD/np.percentile(STD[band],95),0,1)
alpha=np.where(band, np.clip(0.55*lift+0.45*lift*act,0,0.85), 0.0)
alpha[incool]=0.0
mist=np.zeros((NH,NW,4),np.uint8)
mist[:,:,:3]=MIST_RGB.astype(np.uint8)
mist[:,:,3]=(alpha*255).astype(np.uint8)
# un-mix so interior + mist == plate
a=alpha[...,None]
DRY=np.clip((PLATE-MIST_RGB*a)/np.maximum(1-a,1e-3),0,255)

def rgba(mask,src):
    o=np.zeros((NH,NW,4),np.uint8); o[:,:,:3]=src.astype(np.uint8); o[:,:,3]=np.where(mask,255,0)
    return Image.fromarray(o)

rgba(~inwin,PLATE).save(f'{LAY}/frame_foreground.png')
rgba(incool&inwin,PLATE).save(f'{LAY}/cooler_foreground.png')
rgba(inwin&~inres&~incool,DRY).save(f'{LAY}/machine_interior.png')
Image.fromarray(mist).save(f'{LAY}/mist.png')

m=np.zeros((NH,NW,4),np.uint8); m[inres]=[255,255,255,255]
Image.fromarray(m).save(f'{LAY}/reservoir_mask.png')

res=PLATE.copy()
for x in range(*OCC):
    src=min(OCC[1]+(OCC[1]-1-x), WIN['x1']-1)
    res[RES['y0']:RES['y1'],x]=PLATE[RES['y0']:RES['y1'],src]
rgba(inres,res).save(f'{LAY}/reservoir_static.png')

# reflection: coil band above the water, flipped, pulled toward deep water
rh=RES['y1']-RES['y0']; rw=RES['x1']-RES['x0']
b=PLATE[18:18+rh, RES['x0']:RES['x1']][::-1]
b=b*0.80+np.array([23,45,54])*0.20
r=np.zeros((rh,rw,4),np.uint8); r[:,:,:3]=np.clip(b,0,255).astype(np.uint8); r[:,:,3]=255
Image.fromarray(r).save(f'{LAY}/reflection.png')

# drop: 1x5 native, extracted ramp from the reference trail
trail=[(82,117,135,170),(82,117,135,205),(82,117,135,215),(127,171,195,235),(173,202,198,255)]
d=np.zeros((5,1,4),np.uint8)
for i,(rr,gg,bb,aa) in enumerate(trail): d[i,0]=[rr,gg,bb,aa]
Image.fromarray(d).save(f'{LAY}/drop.png')

# palette
q=Image.fromarray(PLATE.astype(np.uint8)).quantize(colors=12,method=Image.MEDIANCUT)
pal=np.array(q.getpalette()[:36]).reshape(12,3); cnt=np.bincount(np.array(q).ravel(),minlength=12)
order=np.argsort(-cnt)
palette=[(f'#{pal[i][0]:02X}{pal[i][1]:02X}{pal[i][2]:02X}', round(100*cnt[i]/cnt.sum(),1)) for i in order]

# water-specific colours from the reservoir band
wat=PLATE[RES['y0']:RES['y1'], 35:95].reshape(-1,3)
deep=np.percentile(wat,10,axis=0); body=np.median(wat,axis=0); hi=np.percentile(wat,97,axis=0)
surf=np.median(PLATE[47, 35:95],axis=0)
def hx(c): return '#%02X%02X%02X'%tuple(np.clip(c,0,255).astype(int))
info=dict(palette=palette, deep=hx(deep), body=hx(body), surface=hx(surf), highlight=hx(hi))
print(json.dumps(info,indent=1))
pass
print("layers ->",sorted(os.listdir(LAY)))
