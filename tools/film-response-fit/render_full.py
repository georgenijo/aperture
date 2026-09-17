import cv2, numpy as np, json, sys, os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__))); from model import *
fitfile, src_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
f=json.load(open(fitfile)); p=Params(); j=f['params']
p.matrix=np.array(j['matrix']); p.curves=np.array(j['curves']); p.sat=np.array(j['saturation']); p.hueChroma=np.array(j['hueChroma']); p.hueRotate=np.array(j['hueRotate']); p.hueLight=np.array(j.get('hueLight',[0]*NBANDS))
v=np.array(f['vignette'])
im=cv2.imread(src_path)[:,:,::-1].astype(np.float32)/255
H,W=im.shape[:2]; ys,xs=np.mgrid[0:H,0:W]; r=np.sqrt(((xs/(W-1)-0.5)*W)**2+((ys/(H-1)-0.5)*H)**2)/(0.5*np.hypot(W,H))
out_im=apply(p,im)*vignette(r.astype(np.float32),v)[...,None]
cv2.imwrite(out,(np.clip(out_im,0,1)[:,:,::-1]*255).astype(np.uint8),[cv2.IMWRITE_JPEG_QUALITY,92])
