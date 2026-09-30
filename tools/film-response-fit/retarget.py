"""Retarget the fitted 1998 response to unpaired target-app statistics (recipe v5).

usage: python retarget.py <targets.json> <base.json> <source_dir> <out_fit.json>

`targets.json` comes from `measure.py` run over target-app photos.
`base.json` is any file holding a `response` block (the committed
`film-response-probes.json` works), whose crosstalk matrix, per-band chroma,
and hue-dependent lightness are kept: they are the only terms the paired v4
fit could actually see. `source_dir` holds ordinary iPhone photos, used only
to measure where saturation and blues start from.

What is solved, and against what:

- Tone curves (red/blue offsets from a shared S-curve): a synthetic grey
  ramp must develop the measured per-band neutral tint (olive shadows,
  lavender mids, cyan highlights). Grey is the one input whose "before" is
  known without a pair, so the tint is attributable to the response.
- Tone-dependent saturation: the mean HSV saturation of the sources must rise
  by the measured target/source ratio.
- Blue-band hue rotation: representative sky/wall blues must rotate by the
  measured target-minus-source blue hue.

Priors keep it a look rather than a scene fit: the green curve is the shared
S-curve, black stays black and white stays white (only interior knots move,
so the cyan tint lives in the highlights without tinting clipped whites),
offsets are smooth, and every term the data cannot see keeps its base value.
"""
import json, os, sys
import numpy as np
from scipy.optimize import least_squares

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import Params, apply, KNOTS, srgb_to_lin, oklab_from_lin
from measure import load, measure, image_paths

# Blue bands the rotation may use (OKLab hue bands of 45 degrees; sky and
# periwinkle-wall blues sit in bands 5 and 6).
BLUE_BANDS = [5, 6]
# Representative iPhone blues (sRGB 0..255): clear sky, periwinkle wall, deep blue.
BLUE_PROBES = np.array([[90, 140, 210], [150, 170, 220], [117, 133, 175], [45, 75, 160]]) / 255.0


def params_from(block):
    p = Params()
    p.matrix = np.array(block['matrix'], dtype=float).reshape(3, 3)
    p.curves = np.array(block['curves'], dtype=float)
    p.sat = np.array(block['saturation'], dtype=float)
    p.hueChroma = np.array(block['hueChroma'], dtype=float)
    p.hueRotate = np.array(block['hueRotate'], dtype=float)
    p.hueLight = np.array(block['hueLight'], dtype=float)
    return p


def hue_degrees(rgb):
    lab = oklab_from_lin(srgb_to_lin(rgb))
    return np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def hsv_saturation(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    return np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)


def main(targets_path, base_path, source_dir, out_path):
    with open(targets_path) as file:
        targets = json.load(file)
    with open(base_path) as file:
        base_block = json.load(file)
    base = params_from(base_block.get('response', base_block.get('params', base_block)))

    # Shared S-curve: the base green channel, with black pinned to 0 and
    # white allowed to reach 1 (the target clips highlights; v4 stopped short).
    shared = base.curves[1].copy()
    shared[0] = 0.0
    shared[-1] = 1.0

    # Neutral tint targets, in encoded units, at each band's mean output grey.
    band_centres, tint_r, tint_b = [], [], []
    for band in targets['neutralBands']:
        if not band.get('images'):
            continue
        lo, hi = band['range']
        band_centres.append((lo + min(hi, 255)) / 2 / 255)
        tint_r.append(band['redMinusGreen'] / 255)
        tint_b.append(band['blueMinusGreen'] / 255)
    band_centres, tint_r, tint_b = map(np.array, (band_centres, tint_r, tint_b))

    paths = image_paths(source_dir)
    if not paths:
        sys.exit(f'no source images in {source_dir}')
    # Source statistics use the same measurement as the targets, so the
    # saturation and blue-hue goals are like-for-like ratios and shifts.
    source_stats = measure(paths)
    if not np.isfinite(source_stats['saturation']) or source_stats['saturation'] <= 0:
        sys.exit('source photos have no measurable saturation; include colour photos to fit saturation')
    if not np.isfinite(targets['saturation']) or targets['saturation'] <= 0:
        sys.exit('target photos have no measurable saturation; include colour photos to fit saturation')
    target_sat_ratio = targets['saturation'] / source_stats['saturation']
    source_blue = source_stats['blueHueDegrees']
    if source_blue is None:
        source_blue = float(np.median(hue_degrees(BLUE_PROBES)))
    if targets['blueHueDegrees'] is None:
        sys.exit('target photos have no clearly blue regions; cannot set the blue rotation')
    blue_shift = targets['blueHueDegrees'] - source_blue
    source_pixels = np.concatenate([load(p, size=320).reshape(-1, 3) / 255 for p in paths])
    source_sat = hsv_saturation(source_pixels).mean()
    if not np.isfinite(source_sat) or source_sat <= 0:
        sys.exit('source photos have no measurable saturation at the fitting resolution')

    grey = np.tile(np.linspace(0.02, 0.98, 49)[:, None], (1, 3))
    interior = slice(1, KNOTS - 1)  # knots 1..7 move; 0 and 8 pin black and white
    n_off = KNOTS - 2

    def build(v):
        p = params_from(base.to_json())
        off_r, off_b = v[0:n_off], v[n_off:2 * n_off]
        p.curves = np.stack([shared.copy(), shared.copy(), shared.copy()])
        p.curves[0, interior] = np.clip(shared[interior] + off_r, 0, 1)
        p.curves[2, interior] = np.clip(shared[interior] + off_b, 0, 1)
        p.sat = v[2 * n_off:2 * n_off + 3]
        p.hueRotate = base.hueRotate.copy()
        p.hueRotate[BLUE_BANDS] = v[2 * n_off + 3:]
        return p

    def residuals(v):
        p = build(v)
        out = apply(p, grey)
        lum = out.mean(-1)
        res = []
        # 1. neutral tint at each band centre (interpolate along the ramp)
        order = np.argsort(lum)
        for c, tr, tb in zip(band_centres, tint_r, tint_b):
            rg = np.interp(c, lum[order], (out[:, 0] - out[:, 1])[order])
            bg = np.interp(c, lum[order], (out[:, 2] - out[:, 1])[order])
            res += [(rg - tr) * 40, (bg - tb) * 40]
        # 2. saturation gain on real sources
        mapped = apply(p, source_pixels)
        res.append((hsv_saturation(mapped).mean() / source_sat - target_sat_ratio) * 8)
        # 3. blues rotate by the measured shift, each from its own hue
        dh = (hue_degrees(apply(p, BLUE_PROBES)) - hue_degrees(BLUE_PROBES) + 180) % 360 - 180
        res += list((dh - blue_shift) / 10)
        # priors: smooth offsets (pinned ends included), saturation ramp gentle
        off = np.pad(v[:2 * n_off].reshape(2, n_off), ((0, 0), (1, 1)))
        res += list(np.diff(off, 2, axis=1).ravel() * 6)
        sat = p.sat
        res += [(sat[0] - sat[1]) * 0.6, (sat[2] - sat[1]) * 0.6]
        return np.array(res)

    v0 = np.concatenate([np.zeros(2 * n_off), [1.0, 1.2, 1.0], base.hueRotate[BLUE_BANDS]])
    lower = np.concatenate([np.full(2 * n_off, -0.08), [0.6, 0.8, 0.6], [-0.2, -0.2]])
    upper = np.concatenate([np.full(2 * n_off, 0.08), [1.6, 1.8, 1.6], [0.6, 0.6]])
    fit = least_squares(residuals, v0, bounds=(lower, upper))
    p = build(fit.x)

    print('grey ramp (in -> out RGB, 0..255):')
    for g in [0.08, 0.25, 0.47, 0.71, 0.91, 1.0]:
        o = apply(p, np.array([[g, g, g]]))[0] * 255
        print(f'  {g * 255:5.0f} -> {o.round(1)}  R-G={o[0] - o[1]:+.1f} B-G={o[2] - o[1]:+.1f}')
    print('white level (99th pct of sources):', round(float(np.percentile(apply(p, source_pixels).mean(-1), 99) * 255), 1),
          'target', targets.get('whiteLevel'))
    print('saturation ratio', round(hsv_saturation(apply(p, source_pixels)).mean() / source_sat, 3),
          'target', round(target_sat_ratio, 3))
    print('blue probes hue', hue_degrees(BLUE_PROBES).round(1), '->', hue_degrees(apply(p, BLUE_PROBES)).round(1),
          f'(target shift {blue_shift:+.1f})')
    with open(out_path, 'w') as file:
        json.dump(dict(params=p.to_json(), targets=targets, source='retarget.py'), file, indent=1)
    print('wrote', out_path)


if __name__ == '__main__':
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
