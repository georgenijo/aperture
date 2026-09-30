# Local Film Lab

A browser tool for tuning Aperture's 1998 look on the Mac, rendered by the app's
own Swift/Core Image renderer. It changes nothing in the app: saved looks are
**recipe candidates**, the input to a later, deliberately versioned app recipe
(see [Promoting a look](#promoting-a-look)).

## Launch

```sh
tools/film-lab/run.sh             # builds if needed, serves http://127.0.0.1:8765, opens the browser
tools/film-lab/run.sh --port 8800 --no-open
tools/film-lab/run.sh --tailnet   # also reachable from your tailnet over HTTPS (see below)
```

The server prints a URL like `http://127.0.0.1:8765/#token=…`. The token is this
session's capability: the page moves it out of the address bar and sends it as a
header on every API/media request. A URL works only while that server is running.
Stop with Ctrl-C.

Requirements: macOS 14+, Xcode command-line tools (Swift 6 compiler, used in
Swift 5 mode with complete concurrency checking) and Python 3.10+. There are no
packages to install and no network access.

`build.sh` compiles the shared renderer closure straight from the app sources,
with the tool sources, into the ignored `tools/film-lab/.build/`:

- `Aperture/Processing/`: `FilmProcessor`, `FilmProcessor+Effects`,
  `FilmProcessor+Overlays`, `FilmProcessor+Rasterization`, `FilmProcessingTypes`,
  `FilmColorModel`, `FilmResponse` and `FilmStage`.
- `Aperture/Models/`: `FilmRecipe`, `DateStamp`, `SeededRandomNumberGenerator`
  and `AppSettings`.

Nothing is stubbed or copied. `build.sh --strict` treats warnings as errors.

## Using it

- **Photos.** Drop or choose JPEG, PNG or HEIC files, or add the three committed
  fixtures (`day-portrait`, `night-flash`, `hdr-still-life`). Up to 12 photos
  form the reference set. Originals are shown with their native orientation and
  colour handling (HEIC and Display P3 included) and are never modified.
- **Compare.** Use before/after (drag the divider or use the arrow keys),
  original only or 1998 only.
- **Controls.** Every control starts at the shipping value. A dot marks the
  ones you've changed. ↺ resets one control exactly and **Reset all to 1998**
  resets them all. The effect toggles switch an optical stage fully off (grain
  included, with no seeded jitter left) and remember its value.
- **Shared settings.** Settings apply to the whole reference set. Switching
  photos keeps them. **Render reference set** renders every photo with the
  settings frozen when you click, at 720 px.
- **Context.** The seed (a decimal UInt64), capture instant, time zone and
  Photo Quality are explicit, so the same settings always give the same pixels.
  Sliders never choose a new seed; only **New seed** does. The panel shows the
  resulting stamp text, whether this seed draws a light leak, and the applied
  recipe fingerprint.

### Controls

Tone controls are bounded, monotone transforms of a copy of the fitted
`FilmResponseStage`. They leave black and white fixed, and they never add a
`colorGrade` stage before resolution. The optical controls set the matching
stage's amount. The authoritative definitions live in
[`controls.json`](controls.json), which drives both the UI and validation. Each
control has exactly one Swift handler in `Sources/LabRecipeBuilder.swift`.

| Group | Controls |
|---|---|
| Tone & colour | brightness, contrast, warm balance, overall/shadow/highlight chroma, crosstalk strength, hue chroma/rotation/lightness correction |
| Optics & texture | halation, softness, colour fringing, grain amount and size, vignette, light-leak strength, light leak (baseline/on/off) |
| Stamp | date stamp (baseline/off) |

How the recipe is built:

1. The shipping 1998 recipe is resolved once for the explicit seed, instant, time
   zone and quality, using the app's default Settings.
2. The Lab adjusts a copy of the result. An unset control inherits the resolved
   value unchanged, and identity transforms are skipped. With no changes the
   applied recipe is identical to direct resolution; the self-tests check this.

Leak overrides keep `lightLeakApplied` and the stage in step. Forcing a leak on
gives it a positive strength.

> [!NOTE]
> Leak occurrence affects the grain seed. Resolution draws the leak's random
> values only when a leak happens, so forcing a leak on or off changes the
> grain pattern too. This is how the app behaves, and the Lab keeps it.

## Preview limits

- **Previews are approximate for texture and optics.** Previews are rendered at
  960, 1280 or 1920 px (JPEG quality 0.85). Grain, softness, halation and
  fringing depend on resolution, so they look different at full size. Softness
  can vanish entirely at small sizes. Colour and tone match full resolution.
- **Full resolution.** **Render full resolution** renders the selected photo at
  its native size with the settings frozen at request time, using the context's
  Photo Quality. You can inspect it 1:1 and download it.
- **Interaction.** Slider changes are debounced (120 ms), so during a continuous
  drag the preview updates once the slider pauses. On an M-series Mac mini a
  1280 px preview of a 12 MP photo appears about 175 ms after the last change.
  Only one render runs at a time. A newer preview request replaces any older
  one still waiting, and the page drops out-of-date results by generation
  number. `window.filmLab.stats`
  records preview latency.
- **Renderer output.** The renderer is `FilmProcessor.shared` from the app. It
  uses an sRGB working space, like the app's still path. A same-size Lab render
  is byte-identical to calling the renderer directly (self-tested).
- **Why the goldens don't match.** The committed goldens come from
  `GoldenRenderTests`, which uses a software `CIContext` with Core Image's
  default linear working space on the iOS Simulator. Two comparisons show the
  difference:
  - `film-lab-renderer compare-golden` renders the goldens both ways on macOS.
    The software path lands close to the goldens, but not within the 1 LSB the
    Simulator achieves. The shared-processor path differs further, mainly in the
    optical stages.
  - Neither result is a Lab defect. Judge looks on real photographs, and confirm
    a promoted recipe on a device.

## Saving, importing and exporting looks

A look is saved as a versioned **recipe-candidate** JSON file:

| Field | Contents |
|---|---|
| `schema`, `schemaVersion` | Identify the candidate format |
| `name` | The look's name |
| `controls` | Only the changed controls |
| `context` | seed, instant, zone, quality |
| `base` | Recipe id, version and fingerprint |
| `controlSchema` | `controls.json` version and digest |
| `provenance` | Tool, git commit, renderer, time |
| `appliedRecipe` | The exact resolved recipe (the seed is an exact integer) |
| `appliedRecipeFingerprint` | Fingerprint of `appliedRecipe` |

It is not an app manifest or a Settings file. Saving or exporting never installs
anything into Aperture.

**Where looks are saved.** Named looks go in
`~/Library/Application Support/Aperture Film Lab/presets/` (outside Git), one
owner-only file per look, written atomically.

- Saving a name that already exists asks before replacing it.
- Deleting asks for confirmation.
- Looks never contain images.

**Import.** Import (and loading a saved look) accepts only supported schemas and
the current baseline.

This build targets the 1998 v5 recipe, including thresholded highlight glow and
screen-blended leaks. Candidates authored against v4 are rejected as a different
base recipe; use the v4 Lab build to inspect them. Reset and the neutral slider
values inherit v5 exactly (glow 0.60, light-leak strength 0.95).

1. The Swift renderer validates the controls and context and rebuilds the recipe
   from them. It never renders imported stage JSON.
2. An included `appliedRecipe` must match the rebuild exactly, both as decoded
   and as written (same fields, same value kinds), so a malformed field that
   the app's decoders would quietly normalise is still caught. Any tampered or
   stale snapshot is rejected.
3. A file from an older `controls.json` digest imports only if its snapshot
   still verifies.

**Big seeds.** Candidate text is treated as opaque by the browser and the Python
server, so a seed above 2^53 is never rounded.

**Downloads.** A full-resolution download is the rendered JPEG. It contains no
camera EXIF, GPS or other source metadata. ImageIO still writes its own minimal
Exif block with pixel dimensions and colour space. That's a metadata property,
separate from pixel fidelity.

## Privacy and local safety

- **Network.**
  - The server binds `127.0.0.1` only.
  - It checks `Host` and `Origin`, and refuses cross-site fetches.
  - It requires the session token for all API and media routes.
  - It sends a strict Content-Security-Policy and no CORS headers.
- **What it serves.** Static files come from a fixed allowlist, and the page
  loads no remote assets.
- **Renderer process.** One persistent renderer process talks to the server
  over newline-delimited JSON on stdin/stdout.
  - Requests carry server-generated paths inside the session directory, never
    image bytes. The renderer re-checks every path with `realpath`.
  - It's recycled after 250 renders and restarted after a crash or a timeout.
- **Uploads and renders.** These live in a private (`0700`) temporary session
  directory. That directory is removed on exit.
- **Limits.**
  - Requests: 64 MB per upload and 256 KB per JSON body, with nesting limits.
  - Images: 60 MP, 12 photos.
  - Retention: 8 previews and 6 explicit jobs.
  - Queue: 2 pending explicit jobs and 16 pending tasks.
  - Concurrency: 2 uploads in flight and 32 open connections. A refused
    upload's body is discarded, never kept.
  - Photos are sniffed by content (JPEG, PNG, HEIC). Truncated files are
    refused.
- **Nothing leaves the Mac** unless you pass `--tailnet`.

### Tailnet access

`--tailnet` runs `tailscale serve --bg --https=<port> http://127.0.0.1:<port>`
for the lifetime of the server, and turns it off on exit.

- The Lab is reachable only by devices on your tailnet, at
  `https://<this-mac>.<tailnet>.ts.net:<port>/#token=…`. It's never exposed to
  the internet (Funnel is not used).
- The server refuses to start the proxy on a port that `tailscale serve` already
  uses.
- The same Host, Origin and token checks apply.

## Tests

```sh
tools/film-lab/build.sh --strict
tools/film-lab/.build/film-lab-renderer selftest --controls tools/film-lab/controls.json --fixtures ApertureTests/Fixtures
python3 -m unittest discover -s tools/film-lab/tests -v
tools/film-lab/.build/film-lab-renderer compare-golden --controls tools/film-lab/controls.json --fixtures ApertureTests/Fixtures
```

**Renderer self-tests** cover:

- Default recipe equals direct resolution, including seeds 0, 2^53+1 and
  UInt64.max, and every Photo Quality.
- Determinism, exact reset, and each control's effect and limits.
- Monotone tone curves, and the leak and stamp overrides.
- Candidate round trips and rejections.
- Path confinement and image validation (type, truncation, pixel cap, HEIC,
  orientation and P3).
- Same-size fidelity against the renderer.

**Server tests** run the real server and renderer and cover:

- Host, Origin and token checks, path traversal and size limits.
- Queue bounds, superseded previews and frozen full-resolution jobs.
- Worker crash, timeout and recycle (output unchanged across recycles).
- Preset persistence and no-overwrite, big-seed round trips, malicious imports
  and session cleanup.

The *Film Lab* GitHub workflow runs all of these on macOS whenever the tool,
the processing/model sources or the fixtures change. The golden comparison is
informational.

## Promoting a look

This tool never promotes anything; promotion is a separate, reviewed app change.

1. Pick the candidate JSON. Its `base.fingerprint` must match the current
   1998 recipe.
2. In the app, bump the 1998 recipe `version`, then bake the candidate's
   `controls` into `FilmRecipeCatalog.nineteenNinetyEight`. Apply the same
   transforms as `LabRecipeBuilder` to the stored constants: the response
   curves, chroma and hue tables, crosstalk, and the stage amounts.
3. Keep existing captures on their persisted recipe. Rendering always uses the
   applied recipe saved with each capture, so old photos keep their look.
4. Regenerate the 1998 goldens deliberately on the Simulator, and update
   `film-response-probes.json` if the response changes. Run the full iOS suite,
   then check on a device.
