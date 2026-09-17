'''Align a reference shot into an original's pixel frame (SIFT + RANSAC homography).

Both inputs MUST already be sRGB-encoded: OpenCV ignores embedded ICC profiles, and the
app evaluates the response in sRGB. iPhone originals are Display P3, so convert first:
  sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" -s format png in.heic --out in.png
'''
import cv2, numpy as np, sys
src_path, huji_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
src = cv2.imread(src_path); huji = cv2.imread(huji_path)
# originals are landscape 4032x3024 EXIF-rotated? check orientation by shape
print('src', src.shape, 'huji', huji.shape)
if src.shape[0] < src.shape[1] and huji.shape[0] > huji.shape[1]:
    src = cv2.rotate(src, cv2.ROTATE_90_CLOCKWISE); print('rotated src ->', src.shape)
g1 = cv2.cvtColor(src, cv2.COLOR_BGR2GRAY); g2 = cv2.cvtColor(huji, cv2.COLOR_BGR2GRAY)
g1 = cv2.createCLAHE(3.0,(8,8)).apply(g1); g2 = cv2.createCLAHE(3.0,(8,8)).apply(g2)
sift = cv2.SIFT_create(nfeatures=20000)
k1,d1 = sift.detectAndCompute(g1,None); k2,d2 = sift.detectAndCompute(g2,None)
m = cv2.BFMatcher().knnMatch(d2,d1,k=2)
good=[a for a,b in m if a.distance < 0.75*b.distance]
p2=np.float32([k2[a.queryIdx].pt for a in good]); p1=np.float32([k1[a.trainIdx].pt for a in good])
H,mask=cv2.findHomography(p2,p1,cv2.RANSAC,4.0)
print('matches',len(good),'inliers',int(mask.sum()))
warped=cv2.warpPerspective(huji,H,(src.shape[1],src.shape[0]))
valid=cv2.warpPerspective(np.full(huji.shape[:2],255,np.uint8),H,(src.shape[1],src.shape[0]))
np.save(out+'-H.npy',H)
cv2.imwrite(out+'-src.png',src); cv2.imwrite(out+'-huji-warped.png',warped); cv2.imwrite(out+'-valid.png',valid)
small=lambda im: cv2.resize(im,None,fx=0.2,fy=0.2,interpolation=cv2.INTER_AREA)
chk=np.zeros_like(small(src)); s1=small(src); s2=small(warped)
t=64; ys,xs=np.mgrid[0:chk.shape[0],0:chk.shape[1]]; tile=((ys//t+xs//t)%2==0)
chk[tile]=s1[tile]; chk[~tile]=s2[~tile]
cv2.imwrite(out+'-checker.jpg',chk)
