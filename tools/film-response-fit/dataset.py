import cv2, numpy as np
import os
FIT_DIR=os.environ.get('FIT_DIR','/tmp/fit')
def load_pair(name, box=16):
    src = cv2.imread(f'{FIT_DIR}/{name}-src.png')[:,:,::-1].astype(np.float32)/255
    huji = cv2.imread(f'{FIT_DIR}/{name}-huji-warped.png')[:,:,::-1].astype(np.float32)/255
    valid = cv2.imread(f'{FIT_DIR}/{name}-valid.png',0) > 250
    H,W = src.shape[:2]
    # gradient mask on source luma (exclude edges: halation + misalignment)
    l = src @ np.array([0.2126,0.7152,0.0722],np.float32)
    gx = cv2.Sobel(l,cv2.CV_32F,1,0,ksize=3); gy = cv2.Sobel(l,cv2.CV_32F,0,1,ksize=3)
    grad = cv2.GaussianBlur(np.sqrt(gx*gx+gy*gy),(0,0),box/2)
    # low-pass
    def lp(im): return cv2.resize(cv2.blur(im,(box,box)),(W//box,H//box),interpolation=cv2.INTER_AREA)
    s = lp(src); h = lp(huji); g = lp(grad)
    v = cv2.resize(valid.astype(np.float32),(W//box,H//box),interpolation=cv2.INTER_AREA) > 0.999
    # stamp region: Huji stamp along left edge lower third in portrait -> exclude x<8% and y>55%
    ys,xs = np.mgrid[0:s.shape[0],0:s.shape[1]]
    nx = xs/(s.shape[1]-1); ny = ys/(s.shape[0]-1)
    stamp = (nx < 0.09) & (ny > 0.5)
    mask = v & ~stamp & (g < 0.05)
    # radius normalised to half-diagonal
    r = np.sqrt(((nx-0.5)*W)**2 + ((ny-0.5)*H)**2)/ (0.5*np.sqrt(W*W+H*H))
    return dict(src=s,huji=h,mask=mask,r=r,name=name,W=W,H=H)
