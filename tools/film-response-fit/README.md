# Film response fit

Fits the `FilmResponseStage` used by the 1998 recipe from aligned pairs of
iPhone originals and reference shots of the same scene taken through the
target film app. Nothing here runs in the app; it produces the numbers pasted
into `FilmRecipeCatalog.nineteenNinetyEight` and the Swift-parity fixture
`ApertureTests/Fixtures/film-response-probes.json`.

The reference images are not committed (they are George's personal photos).
The pipeline expects them in a scratch directory, `FIT_DIR` (default
`/tmp/fit`).

## Steps

```sh
python3 -m venv .venv && .venv/bin/pip install numpy pillow opencv-python-headless scipy
export FIT_DIR=/tmp/fit && mkdir -p "$FIT_DIR"

# 1. Align each reference shot into its original's pixel frame (SIFT + RANSAC
#    homography). Originals are the app's preserved `original.heic` converted to
#    PNG with `sips -s format png`.
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

Everything is smooth and monotone so the stage bakes cleanly into the 32³
`CIColorCube` shared by stills and video.

## Why a constrained parametric fit and not a free 3D LUT

The reference pairs are two shots of one dark desk scene. A free LUT (or an
unconstrained fit of this model) collapses outside that data: it crushed
red and green above the midtones, painted neutrals magenta, and treated the
moved hand as a colour transform. The priors in `fit.py` encode what the
data cannot: highlights end at white, per-channel curves stay close to one
shared S-curve, neutrals stay warm rather than magenta, hue bands with no
samples stay at zero, and the fit is anchored by skin and region medians
measured separately in each image so misalignment cannot bias them.
