"""Measure look statistics from a directory of target-app photos (no pairs needed).

usage: python measure.py <reference_dir> [out.json]

The 1998 v4 fit came from one aligned desk-scene pair and could not see how
the target treats neutrals across the tonal range, saturation, or blues.
These are unpaired, scene-averaged statistics, so each is kept deliberately
coarse and robust to content:

- neutral tint: mean (R-G, B-G) of near-neutral pixels in five luminance
  bands, in 0..255 code values;
- saturation: mean HSV saturation;
- blue hue: mean OKLab hue (degrees) of clearly blue pixels;
- white level: 99th percentile of mean-RGB luminance.

`retarget.py` turns these into response parameters.
"""
import io, json, os, sys
import numpy as np
from PIL import Image, ImageCms, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import srgb_to_lin, oklab_from_lin

BANDS = [(0, 40), (40, 90), (90, 150), (150, 210), (210, 256)]
NEUTRAL_SPREAD = 28  # max-min channel spread (code values) that still counts as neutral


EXTENSIONS = ('.jpg', '.jpeg', '.png', '.webp')  # convert HEIC with `sips` first (see README)


def image_paths(directory):
    return sorted(os.path.join(directory, n) for n in os.listdir(directory)
                  if n.lower().endswith(EXTENSIONS))


def load(path, size=600):
    with Image.open(path) as source:
        profile = source.info.get('icc_profile')
        im = ImageOps.exif_transpose(source).convert('RGB')
        if profile:
            try:
                im = ImageCms.profileToProfile(
                    im, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                    ImageCms.createProfile('sRGB'), outputMode='RGB')
            except (ImageCms.PyCMSError, OSError, TypeError, ValueError) as error:
                raise ValueError(f'{path}: cannot convert embedded colour profile to sRGB') from error
        # Untagged images are assumed sRGB. Convert before resizing so the
        # same encoded domain feeds target and source measurements.
        im.thumbnail((size, size))
        return np.asarray(im).astype(float)


def image_stats(a):
    lum = a.mean(axis=2)
    spread = a.max(axis=2) - a.min(axis=2)
    neutral = spread < NEUTRAL_SPREAD
    tints = []
    for lo, hi in BANDS:
        m = neutral & (lum >= lo) & (lum < hi)
        tints.append(a[m].mean(axis=0) if m.sum() > 200 else None)
    mx, mn = a.max(axis=2), a.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0).mean()
    lab = oklab_from_lin(srgb_to_lin(a / 255))
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
    blue = (chroma > 0.06) & (hue > 220) & (hue < 300)
    blue_hue = float(hue[blue].mean()) if blue.sum() > 500 else None
    return tints, float(sat), blue_hue, float(np.percentile(lum, 99))


def measure(paths):
    band_acc = [[] for _ in BANDS]
    sats, blues, whites = [], [], []
    for p in paths:
        tints, sat, blue_hue, white = image_stats(load(p))
        for k, t in enumerate(tints):
            if t is not None:
                band_acc[k].append(t)
        sats.append(sat); whites.append(white)
        if blue_hue is not None:
            blues.append(blue_hue)
    bands = []
    for (lo, hi), acc in zip(BANDS, band_acc):
        if not acc:
            bands.append(dict(range=[lo, hi], images=0)); continue
        v = np.median(np.array(acc), axis=0)  # median across images: one scene cannot dominate
        bands.append(dict(range=[lo, hi], images=len(acc),
                          redMinusGreen=round(float(v[0] - v[1]), 2),
                          blueMinusGreen=round(float(v[2] - v[1]), 2)))
    return dict(images=len(paths), neutralBands=bands,
                saturation=round(float(np.median(sats)), 3),
                blueHueDegrees=round(float(np.median(blues)), 1) if blues else None,
                blueImages=len(blues),
                whiteLevel=round(float(np.median(whites)), 1))


if __name__ == '__main__':
    paths = image_paths(sys.argv[1])
    if not paths:
        sys.exit(f'no images in {sys.argv[1]}')
    result = measure(paths)
    text = json.dumps(result, indent=1)
    if len(sys.argv) > 2:
        with open(sys.argv[2], 'w') as file:
            file.write(text + '\n')
    print(text)
