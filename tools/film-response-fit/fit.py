"""Fit the 1998 film response from two aligned reference pairs (see README).

Inputs (in $FIT_DIR, produced by align.py): pair{1,2}-src.png,
pair{1,2}-huji-warped.png, pair{1,2}-valid.png. Output: $FIT_DIR/fit.json.
"""
import numpy as np, json, sys, cv2
from scipy.optimize import least_squares
import os
FIT_DIR=os.environ.get('FIT_DIR','/tmp/fit')
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__))); from dataset import load_pair; from model import *
pairs=[load_pair('pair1',box=8),load_pair('pair2',box=8)]
# exclude the moving hand (pair2 lower-left) spatially
d=pairs[1]; hh,ww=d['mask'].shape; ys,xs=np.mgrid[0:hh,0:ww]; d['mask']&=~((xs/ww<0.42)&(ys/hh>0.52))
print('samples per pair',[p['mask'].sum() for p in pairs])
S=[];Hj=[];R=[]
for d in pairs:
    m=d['mask']; S.append(d['src'][m]); Hj.append(d['huji'][m]); R.append(d['r'][m])
S=np.concatenate(S); Hj=np.concatenate(Hj); R=np.concatenate(R)
# --- anchors: skin via hue mask over the hand area of pair2, plus desk/lamp/keyboard medians
def skin_median(path, box):
    im=cv2.imread(path)[:,:,::-1].astype(np.float32)/255
    x0,y0,x1,y1=[v*4 for v in box]; reg=im[y0:y1,x0:x1].reshape(-1,3)
    lab=oklab_from_lin(srgb_to_lin(reg)); hue=np.degrees(np.arctan2(lab[:,2],lab[:,1]))%360; ch=np.hypot(lab[:,1],lab[:,2])
    m=(hue>20)&(hue<75)&(ch>0.06)&(lab[:,0]>0.25)
    sel=reg[m]; l=sel@np.array([0.2126,0.7152,0.0722]); top=l>np.quantile(l,0.5)
    return np.median(sel[top],0), np.median(sel[~top],0)
skinS_hi,skinS_lo=skin_median(''+FIT_DIR+'/pair2-src.png',(0,560,300,1000)); skinH_hi,skinH_lo=skin_median(''+FIT_DIR+'/pair2-huji-warped.png',(0,560,300,1000))
print('skin hi',(skinS_hi*255).round(0),'->',(skinH_hi*255).round(0)); print('skin lo',(skinS_lo*255).round(0),'->',(skinH_lo*255).round(0))
def med(name,box):
    s=cv2.imread(f'{FIT_DIR}/{name}-src.png')[:,:,::-1].astype(np.float32)/255; h=cv2.imread(f'{FIT_DIR}/{name}-huji-warped.png')[:,:,::-1].astype(np.float32)/255
    x0,y0,x1,y1=[v*4 for v in box]; return np.median(s[y0:y1,x0:x1].reshape(-1,3),0), np.median(h[y0:y1,x0:x1].reshape(-1,3),0)
anchors=[(skinS_hi,skinH_hi,400),(skinS_lo,skinH_lo,300),(*med('pair1',(565,405,620,435)),40),(*med('pair1',(270,170,330,250)),20),(*med('pair2',(630,400,700,470)),20)]
AS=np.array([a[0] for a in anchors]); AH=np.array([a[1] for a in anchors]); AW=np.array([a[2] for a in anchors],float)
labS=oklab_from_lin(srgb_to_lin(S)); labH=oklab_from_lin(srgb_to_lin(Hj)); labAH=oklab_from_lin(srgb_to_lin(AH))
lum=S@np.array([0.2126,0.7152,0.0722]); hue=np.arctan2(labS[:,2],labS[:,1]); chroma=np.hypot(labS[:,1],labS[:,2])
lb=np.clip((lum*8).astype(int),0,7); hb=np.where(chroma<0.03,8,((hue/(2*np.pi))%1*8).astype(int)); cell=lb*9+hb
cnt=np.bincount(cell,minlength=72).astype(float); w=1/np.maximum(cnt[cell],1); w=np.minimum(w/w.mean(),15); w/=w.mean()
xk=np.linspace(0,1,KNOTS); prior=np.clip(smoothstep(0.02,0.98,xk),0,1)
def unpack(x):
    p=Params(); i=0
    p.matrix=x[i:i+9].reshape(3,3); i+=9
    shared=x[i:i+KNOTS]; i+=KNOTS
    ch=x[i:i+3*KNOTS].reshape(3,KNOTS); i+=3*KNOTS
    p.curves=np.clip(prior+shared+ch,0,1)
    p.sat=x[i:i+3]; i+=3
    p.hueChroma=x[i:i+NBANDS]; i+=NBANDS; p.hueRotate=x[i:i+NBANDS]; i+=NBANDS; p.hueLight=x[i:i+NBANDS]; i+=NBANDS
    return p,x[i:i+3],shared,ch
def build_resid(keep):
    Sk,Rk,wk,labHk=S[keep],R[keep],w[keep],labH[keep]; sw=np.sqrt(wk/len(Sk))*100; aw=np.sqrt(AW)
    def resid(x):
        p,v,shared,ch=unpack(x)
        pred,gneg,gpos=apply_gamut(p,Sk); pred=pred*vignette(Rk,v)[:,None]
        e=(oklab_from_lin(srgb_to_lin(pred))-labHk)*np.array([1.0,1.5,1.5])
        pa,aneg,apos=apply_gamut(p,AS)
        ea=(oklab_from_lin(srgb_to_lin(pa))-labAH)*np.array([1.0,1.5,1.5])
        gam=np.concatenate([gneg*sw*4, aneg*aw*4, gpos*sw*2, apos*aw*2])   # anchors: centre-ish, no vignette
        slope=np.diff(prior+shared+ch,axis=1)*(KNOTS-1)
        curves=prior+shared+ch
        magenta=np.minimum(curves[1]-(curves[0]+curves[2])/2,0)     # green below the red/blue mean -> magenta greys
        cool=np.minimum(curves[0]-curves[2],0)                        # blue above red -> cool greys
        reg=[ magenta*120.0, cool*40.0, (p.matrix-np.eye(3)).ravel()*8.0, np.diff(shared,2)*4.0, shared*0.3,
              ch.ravel()*3.0, np.diff(ch,2,axis=1).ravel()*10.0, np.minimum(slope-0.35,0).ravel()*300.0,
              p.hueChroma*1.0, p.hueRotate*1.5, p.hueLight*1.0, (p.sat-1)*1.0 ]
        return np.concatenate([(e*sw[:,None]).ravel(),(ea*aw[:,None]).ravel(),gam]+reg)
    return resid
x0=np.concatenate([np.eye(3).ravel(), np.zeros(KNOTS), np.zeros(3*KNOTS), np.ones(3), np.zeros(3*NBANDS), [0.2,0.4,1.5]])
lo=np.full_like(x0,-np.inf); hi=np.full_like(x0,np.inf); i=0
lo[i:i+9]=-0.15; hi[i:i+9]=1.2; lo[[0,4,8]]=0.7; i+=9
lo[i:i+KNOTS]=-0.3; hi[i:i+KNOTS]=0.3; i+=KNOTS
lo[i:i+3*KNOTS]=-0.12; hi[i:i+3*KNOTS]=0.12; i+=3*KNOTS
lo[i:i+3]=0.4; hi[i:i+3]=1.8; i+=3
for _ in range(3): lo[i:i+NBANDS]=-0.25; hi[i:i+NBANDS]=0.25; i+=NBANDS
lo[i:i+3]=[0,0.1,0.8]; hi[i:i+3]=[0.7,0.8,3]
keep=np.ones(len(S),bool)
for it in range(2):
    r=least_squares(build_resid(keep),x0,bounds=(lo,hi),loss='soft_l1',f_scale=0.04,max_nfev=300,verbose=0)
    x0=r.x; p,v,shared,ch=unpack(r.x)
    pred=apply(p,S)*vignette(R,v)[:,None]
    e=np.linalg.norm(oklab_from_lin(srgb_to_lin(pred))-labH,axis=1); keep=e<np.percentile(e,90)
    print(f'pass {it}: cost {r.cost:.3f} medianErr {np.median(e):.4f}')
json.dump(dict(params=p.to_json(),vignette=v.tolist()),open(f'{FIT_DIR}/fit.json','w'),indent=1)
np.set_printoptions(linewidth=150)
print('curves*255\n',(p.curves*255).round(0)); print('matrix\n',p.matrix.round(3)); print('sat',p.sat.round(3))
print('hueChroma',p.hueChroma.round(3)); print('hueRotate',p.hueRotate.round(3)); print('hueLight',p.hueLight.round(3)); print('vignette',v.round(3))
print('anchors pred vs huji:'); 
for a,(s_,h_,w_) in zip(apply(p,AS),anchors): print((a*255).round(0),(h_*255).round(0))
print('mean abs err (kept)/255:',(np.abs(pred-Hj)[keep].mean(0)*255).round(1))
