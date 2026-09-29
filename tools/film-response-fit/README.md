# Film response fit

Fits the `FilmResponseStage` used by the 1998 recipe. Recipe version 4 was
fitted from aligned pairs of iPhone originals and reference shots of the
same scene taken through the target film app; version 5 keeps that fit's
matrix and per-hue chroma/lightness and retargets the tone curves,
saturation, and blue-band rotation to unpaired statistics measured across
many target-app photos (see "Retargeting" below). Nothing here runs in the app; it produces the numbers pasted
into `FilmRecipeCatalog.nineteenNinetyEight` and the Swift-parity fixture
`ApertureTests/Fixtures/film-response-probes.json`.

The reference images are not committed (the pairs are George's personal
photos; the retarget set is public third-party photos used only as
measurement targets).
The pipeline expects them in a scratch directory, `FIT_DIR` (default
`/tmp/fit`).

## Steps

```sh
python3 -m venv .venv && .venv/bin/pip install numpy pillow opencv-python-headless scipy
export FIT_DIR=/tmp/fit && mkdir -p "$FIT_DIR"

# 1. Convert every input to sRGB first: OpenCV ignores ICC profiles and the app
#    evaluates the response in sRGB, but iPhone originals are Display P3.
sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" -s format png original.heic --out original.png
#    Then align each reference shot into its original's pixel frame (SIFT +
#    RANSAC homography).
.venv/bin/python align.py <original.png> <reference.jpg> "$FIT_DIR/pair1"
.venv/bin/python align.py <original.png> <reference.jpg> "$FIT_DIR/pair2"

# 2. Fit. `fit.py` loads pair1/pair2, masks the moving hand, low-passes both
#    images, balances samples across luminance/hue cells, anchors skin and
#    a few region medians, and regresses the model with a warm-neutral prior.
.venv/bin/python fit.py            # writes "$FIT_DIR/fit.json"

# 3. Preview the fitted response on any image (pure Python, no Core Image).
.venv/bin/python render_full.py "$FIT_DIR/fit.json" <source.jpg> <out.jpg>

# 4. Export the Swift literal and the parity fixture.
.venv/bin/python export.py "$FIT_DIR/fit.json"
```

## Retargeting (recipe v5)

One dark desk scene cannot show how the target treats neutrals across the
tonal range, overall saturation, or blues, so v5 measures those from a
folder of target-app photos instead. No pairs are needed:

```sh
# Target statistics: per-band neutral tint, saturation, blue hue, white level.
.venv/bin/python measure.py <target_photos_dir> "$FIT_DIR/targets.json"

# Re-solve red/blue curve offsets, the saturation quadratic, and the blue
# hue bands against those targets, starting from the committed response.
# <source_dir> holds only original iPhone photos (not developed goldens): the
# saturation and blue goals are ratios/shifts relative to them.
.venv/bin/python retarget.py "$FIT_DIR/targets.json" \
  ../../ApertureTests/Fixtures/film-response-probes.json <source_dir> "$FIT_DIR/fit.json"

.venv/bin/python export.py "$FIT_DIR/fit.json"
```

The 2026-09 measurement over 30 Huji photos gave olive shadows, lavender
mids (red and blue ~9 code values over green), cyan-mint highlights (red
~10 under green), ~25% more saturation than iPhone sources, and blues about
23° further toward violet. A grey ramp is the one input whose "before" is
known without a pair, so the neutral tint is matched on a synthetic ramp
through the full model. Scene-averaged statistics are coarse; the priors
(shared green S-curve, smooth offsets, pinned black and white) keep the
result a look rather than a scene fit: the cyan tint sits in the upper
highlights (~232) while clipped white stays white, and the target's lower
white level (~234) comes from the scene, not from greying the curve top.
`measure.py` and `retarget.py` read `.jpg/.jpeg/.png/.webp` in any case;
convert HEIC with `sips` first. The v5 gates are the tint, blue,
and saturation tests in `FilmResponseModelTests`.

The measurement loader converts embedded ICC profiles (including Display P3)
to sRGB before resizing; untagged images are assumed sRGB. An invalid profile
is rejected rather than silently measured in the wrong colour space. Both
photo sets must contain measurable colour; grayscale-only sets are rejected
with a validation message. Run the offline regression checks with:

```sh
.venv/bin/python -m unittest discover -s tests
```

## Model

`model.py::apply` is the reference implementation; `FilmResponseModel.map`
in `Aperture/Processing/FilmResponse.swift` mirrors it term by term and
`FilmResponseModelTests.testSwiftPortMatchesPythonReferenceProbes` pins the
two together to half a code value.

1. sRGB decode, 3×3 crosstalk matrix in linear light (rows renormalised).
2. Per-channel monotone tone curve on the encoded domain: nine uniformly
   spaced knots, Fritsch–Carlson (PCHIP) interpolation.
3. OKLab: chroma gain as a quadratic in lightness (values at L = 0, ½, 1)
   plus per-hue-band additive chroma, hue rotation, and chroma-weighted
   lightness change over eight periodic bands.

Every term is smooth and the channel curves are monotone, so the stage bakes
cleanly into the 32³ `CIColorCube` shared by stills and video.

## Why a constrained parametric fit and not a free 3D LUT

The reference pairs are two shots of one dark desk scene. A free LUT (or an
unconstrained fit of this model) collapses outside that data: it crushed
red and green above the midtones, painted neutrals magenta, and treated the
moved hand as a colour transform. The priors in `fit.py` encode what the
data cannot: highlights end at white (the top knots are pinned), per-channel curves
are a shared S-curve plus a red offset, a non-negative red-minus-blue term
and a small non-negative green-above-mean term (so greys cannot go cool or
magenta by construction; a green cast is only bounded), hue
bands with no samples stay at zero, and the fit is anchored by skin and region medians
measured separately in each image so misalignment cannot bias them.

That warm-neutral prior was a guess the pairs could not check. The v5
measurement across many target-app photos contradicted it (their
highlights run cyan and their mids lavender), which is why `retarget.py`
replaces it with measured targets rather than extending `fit.py`.
