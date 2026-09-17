import numpy as np
# ---- colour model (numpy, vectorised). Must be mirrored exactly in Swift FilmColorModel.
def srgb_to_lin(c): return np.where(c<=0.04045, c/12.92, ((c+0.055)/1.055)**2.4)
def lin_to_srgb(c):
    c=np.clip(c,0,None); return np.where(c<=0.0031308, c*12.92, 1.055*np.power(c,1/2.4)-0.055)
def smoothstep(e0,e1,x):
    t=np.clip((x-e0)/(e1-e0),0,1); return t*t*(3-2*t)
KNOTS = 9  # per channel, knot x positions uniform in encoded domain (0..1); y monotone
def pchip_eval(xk, yk, x):
    # monotone piecewise-cubic (Fritsch–Carlson) interpolation, mirrors Swift
    n=len(xk); h=np.diff(xk); d=np.diff(yk)/h
    m=np.zeros(n)
    m[0]=d[0]; m[-1]=d[-1]
    for i in range(1,n-1):
        if d[i-1]*d[i] <= 0: m[i]=0
        else:
            w1=2*h[i]+h[i-1]; w2=h[i]+2*h[i-1]
            m[i]=(w1+w2)/(w1/d[i-1]+w2/d[i])
    i=np.clip(np.searchsorted(xk,x,side='right')-1,0,n-2)
    t=(x-xk[i])/h[i]; hh=h[i]
    h00=2*t**3-3*t**2+1; h10=t**3-2*t**2+t; h01=-2*t**3+3*t**2; h11=t**3-t**2
    return h00*yk[i]+h10*hh*m[i]+h01*yk[i+1]+h11*hh*m[i+1]
def oklab_from_lin(l):
    r,g,b=l[...,0],l[...,1],l[...,2]
    L=0.4122214708*r+0.5363325363*g+0.0514459929*b
    M=0.2119034982*r+0.6806995451*g+0.1073969566*b
    S=0.0883024619*r+0.2817188376*g+0.6299787005*b
    L,M,S=np.cbrt(np.clip(L,0,None)),np.cbrt(np.clip(M,0,None)),np.cbrt(np.clip(S,0,None))
    return np.stack([0.2104542553*L+0.7936177850*M-0.0040720468*S,
                     1.9779984951*L-2.4285922050*M+0.4505937099*S,
                     0.0259040371*L+0.7827717662*M-0.8086757660*S],-1)
def lin_from_oklab(lab):
    L,a,b=lab[...,0],lab[...,1],lab[...,2]
    l=(L+0.3963377774*a+0.2158037573*b)**3
    m=(L-0.1055613458*a-0.0638541728*b)**3
    s=(L-0.0894841775*a-1.2914855480*b)**3
    return np.stack([4.0767416621*l-3.3077115913*m+0.2309699292*s,
                     -1.2684380046*l+2.6097574011*m-0.3413193965*s,
                     -0.0041960863*l-0.7034186147*m+1.7076147010*s],-1)
NBANDS=8
def band_eval(vals, hue):  # periodic piecewise-linear over NBANDS bands, hue in radians
    t=(hue/(2*np.pi))%1.0*NBANDS; i=np.floor(t).astype(int)%NBANDS; f=t-np.floor(t)
    return vals[i]*(1-f)+vals[(i+1)%NBANDS]*f
class Params:
    names=['matrix','curves','sat','hueChroma','hueRotate']
    def __init__(self):
        self.matrix=np.eye(3)            # applied in linear light, rows renormalised to sum 1
        self.curves=np.tile(np.linspace(0,1,KNOTS),(3,1))  # per-channel encoded-domain knots
        self.sat=np.array([1.0,1.0,1.0])  # chroma gain at shadows, mids, highlights (OKLab L 0/0.5/1)
        self.hueChroma=np.zeros(NBANDS)   # additive chroma gain per band
        self.hueRotate=np.zeros(NBANDS)   # radians per band
        self.hueLight=np.zeros(NBANDS)    # fractional OKLab L change per band
    def vec(self):
        return np.concatenate([self.matrix.ravel(), self.curves.ravel(), self.sat, self.hueChroma, self.hueRotate, self.hueLight])
    @staticmethod
    def from_vec(v):
        p=Params(); i=0
        p.matrix=v[i:i+9].reshape(3,3); i+=9
        p.curves=v[i:i+3*KNOTS].reshape(3,KNOTS); i+=3*KNOTS
        p.sat=v[i:i+3]; i+=3
        p.hueChroma=v[i:i+NBANDS]; i+=NBANDS
        p.hueRotate=v[i:i+NBANDS]; i+=NBANDS
        p.hueLight=v[i:i+NBANDS]; i+=NBANDS
        return p
    def to_json(self):
        return dict(matrix=self.matrix.tolist(), curves=self.curves.tolist(), saturation=self.sat.tolist(),
                    hueChroma=self.hueChroma.tolist(), hueRotate=self.hueRotate.tolist(), hueLight=self.hueLight.tolist())
def apply(p, c):
    """c: (...,3) sRGB encoded 0..1 -> sRGB encoded."""
    lin=srgb_to_lin(np.clip(c,0,1))
    M=p.matrix/np.sum(p.matrix,axis=1,keepdims=True)
    lin=np.clip(lin@M.T,0,None)
    enc=lin_to_srgb(lin)
    xk=np.linspace(0,1,KNOTS)
    out=np.empty_like(enc)
    for ch in range(3):
        yk=np.maximum.accumulate(np.clip(p.curves[ch],0,1))  # enforce monotone
        out[...,ch]=np.clip(pchip_eval(xk,yk,np.clip(enc[...,ch],0,1)),0,1)
    lab=oklab_from_lin(srgb_to_lin(out))
    L=lab[...,0]; a=lab[...,1]; b=lab[...,2]
    chroma=np.sqrt(a*a+b*b); hue=np.arctan2(b,a)
    # tone-dependent chroma gain: quadratic through (0,s0),(0.5,s1),(1,s2)
    s0,s1,s2=p.sat
    tg=s0*(1-L)*(1-2*L)+s1*4*L*(1-L)+s2*L*(2*L-1)
    gain=np.clip(tg+band_eval(p.hueChroma,hue),0,None)
    hue2=hue+band_eval(p.hueRotate,hue)
    chroma2=chroma*gain
    # hue-dependent lightness, weighted by chroma so greys are untouched
    L2=np.clip(L*(1+band_eval(p.hueLight,hue)*np.clip(chroma/0.12,0,1)),0,1)
    lab2=np.stack([L2,chroma2*np.cos(hue2),chroma2*np.sin(hue2)],-1)
    return np.clip(lin_to_srgb(lin_from_oklab(lab2)),0,1)
def vignette(r, v):  # v = [strength, start, power]
    return 1 - v[0]*smoothstep(v[1],1.0,r)**v[2]

def apply_gamut(p, c):
    """Like apply() but also returns the minimum pre-clip linear channel value (for a gamut penalty)."""
    lin=srgb_to_lin(np.clip(c,0,1))
    M=p.matrix/np.sum(p.matrix,axis=1,keepdims=True)
    lin=np.clip(lin@M.T,0,None)
    enc=lin_to_srgb(lin)
    xk=np.linspace(0,1,KNOTS)
    out=np.empty_like(enc)
    for ch in range(3):
        yk=np.maximum.accumulate(np.clip(p.curves[ch],0,1))
        out[...,ch]=np.clip(pchip_eval(xk,yk,np.clip(enc[...,ch],0,1)),0,1)
    lab=oklab_from_lin(srgb_to_lin(out))
    L=lab[...,0]; a=lab[...,1]; b=lab[...,2]
    chroma=np.sqrt(a*a+b*b); hue=np.arctan2(b,a)
    s0,s1,s2=p.sat
    tg=s0*(1-L)*(1-2*L)+s1*4*L*(1-L)+s2*L*(2*L-1)
    gain=np.clip(tg+band_eval(p.hueChroma,hue),0,None)
    hue2=hue+band_eval(p.hueRotate,hue)
    chroma2=chroma*gain
    L2=np.clip(L*(1+band_eval(p.hueLight,hue)*np.clip(chroma/0.12,0,1)),0,1)
    lab2=np.stack([L2,chroma2*np.cos(hue2),chroma2*np.sin(hue2)],-1)
    linout=lin_from_oklab(lab2)
    return np.clip(lin_to_srgb(linout),0,1), np.minimum(linout.min(-1),0), np.maximum(linout.max(-1)-1,0)
