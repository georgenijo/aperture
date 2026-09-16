# Aperture implemented architecture

This document describes the code in the current v1 branch. It covers stills and the implemented short-film path.

## Product principles

Capture should feel immediate; the film character belongs to development, not to a blocked camera session. The Lab is the local archive and the app should remain useful without an account, network, analytics, or Photos read access. Every device capability is discovered rather than assumed, and every persisted visual decision is reproducible.

## Runtime ownership and concurrency

`AppModel` is `@MainActor` and owns the app-facing state. `CameraManager` serializes AVFoundation graph/device/output work on `CameraSessionQueue` (`com.georgenijo.Aperture.camera-session`) and publishes snapshots back to the UI. `MediaLibrary` is an actor; `ThumbnailService` and `PhotosExporter` are actors. Film rendering runs on a bounded concurrent queue and is called from detached user-initiated work. This prevents capture/session configuration and disk/GPU work from competing on the main actor.

Capture flow:

```text
tap shutter
  -> AVCapturePhotoOutput callback
  -> commit processed camera bytes (+ optional original) to MediaLibrary
  -> mark processing and render on background work
  -> atomically replace processed asset, mark ready
  -> refresh Lab / optional add-only Photos export
```

## Camera and virtual lens mapping

The manager discovers a back virtual multi-camera device where available and a wide-angle/TrueDepth fallback for front capture. It reads `virtualDeviceSwitchOverVideoZoomFactors`, `activeFormat.secondaryNativeResolutionZoomFactors`, min/max raw zoom, flash modes, focus/exposure support, and macro fallback. `LensOptionMapper` converts those raw factors into bounded camera-style display stops (up to 10× by default), deduplicating nearby values and preserving optical transition points. The displayed value is a device-derived multiplier; the raw value is what AVFoundation receives.

Zoom can be set or ramped. A tap is converted through `AVCaptureVideoPreviewLayer` into a normalized device point and applies focus and exposure only when supported. Captured metadata records camera position/device, raw/display zoom, switch-over factors, flash, exposure/ISO snapshot, and macro availability.

## Capture responsiveness

The photo output uses the highest supported dimensions and quality prioritization. On iOS 17+ it explicitly disables automatic deferred photo delivery, then enables zero-shutter-lag, responsive capture, and fast-capture prioritization only when the output reports support. A readiness coordinator is installed so UI readiness can follow the output.

Deferred proxy delivery is deliberately off: the first committed asset must be the actual camera result, and the Lab should not have to replace a proxy later or risk developing a lower-fidelity intermediate. The trade-off is more work/memory at capture time; pressure and interruption states are surfaced for device verification.

Video mode reconfigures the same serialized session with `AVCaptureMovieFileOutput` and an audio input after microphone authorization. It records a file-backed `.mov` in the temporary directory, applies rotation/stabilization when supported, and stops automatically at 60 seconds. Leaving the foreground safely closes the recording. The resulting `CapturedVideo` preserves duration, dimensions, camera metadata, and source URL; `AppModel` copies that URL into the media library before development.

## Deterministic film pipeline

`FilmRecipeCatalog` currently contains 1998, Night, Cinema, and a legacy-original recipe. A recipe is an ordered list of `FilmStage` values (colour grade, halation, softness, chromatic aberration, grain, light leak, vignette, date stamp); the array order is the processing order and every constant an effect uses lives in its stage struct, so a new look is a data change rather than a new code path. Version-1 manifests persisted a flat `FilmParameters` set and decode through `FilmStage.legacyPipeline`, which reproduces the original fixed order; `GoldenRenderTests` pins the pixel output of the catalog recipes. At capture, a seed, capture timestamp, selected Photo Quality, and processing options resolve settings (including whether a light leak is selected, the exact date-stamp text, and JPEG compression quality) into `AppliedFilmRecipe`, which is persisted with the item. `FilmProcessor` rejects unsupported recipe versions and invalid extents, uses one reusable sRGB `CIContext`, and bounds concurrent renders with two permits. Re-development reads the persisted compression quality, so changing Settings cannot change an existing item’s encoding.

The implemented order is: normalize orientation, choose full/preview render size, tone curve, color response (exposure/contrast/saturation/warmth/highlights/shadows), bloom/halation, softness, chromatic aberration, seeded grain, optional seeded light leak, vignette, and persisted date stamp. It renders to finite sRGB RGBA and encodes through Image I/O (JPEG for developed stills). Thumbnails are a separate deterministic downsample of the processed image; they do not alter the full-resolution export.

`VideoProcessor` uses an `AVAssetExportSession` video composition. Color/tone/halation/vignette, the light-leak decision, and the persisted date-stamp overlay stay static for the whole clip; grain evolves from a deterministic `(recipe.seed, frameIndex)` temporal seed and a small noise bank. The exporter preserves source audio when present, validates a playable output, and writes a `.mov` (or supported fallback type). Video playback is provided by `AVPlayer` in `PhotoDetailView`; the same processed URL is used for sharing and add-only Photos export.

## Storage, transactions, migration, and cache

The default root is Application Support `Aperture/MediaLibrary`:

```text
library.json
legacy-deletions.json              (durable tombstones for deleted legacy imports)
media/<uuid>/item.json
media/<uuid>/processed.<ext>
media/<uuid>/original.<ext>       (optional)
media/<uuid>/thumbnail.<ext>      (optional persisted asset)
staging/                           (incomplete creation/deletion transactions)
recovery/                          (corrupt manifests and quarantined data)

Library/Caches/ApertureThumbnails/
  .aperture-thumbnail-version      (renderer/schema marker)
  <item-uuid>-<hash>.jpg           (discoverable derived thumbnails)
```

`MediaLibrary` validates safe relative paths and file extensions. Creation writes a complete item into staging, moves it into `media/<uuid>`, then atomically writes the manifest. Replacement materializes a uniquely named new processed asset, publishes item metadata and the index, and only then removes superseded processed/thumbnail files; if metadata rollback is uncertain, the new asset is retained for reconciliation. At launch, committed item metadata is reconciled with the index, and orphan cleanup runs only when all referenced assets are present, preserving a viable older asset when a replacement reference is damaged. Deletion moves the item to a deletion staging directory, updates the manifest, then removes the staged directory. Startup reconciles interrupted operations, missing files, corrupt manifests, and incomplete staging, retaining diagnostics and recovery copies.

The older `Documents/photos/*.json` + image layout is imported by stable legacy identifier. Migration copies data, marks provenance as `legacyImport`, uses the `legacy-original` recipe, and leaves legacy files untouched. Deleted imported identifiers are written atomically to durable `legacy-deletions.json` tombstones so an untouched legacy source cannot be re-imported. If the ledger is corrupt, a recovery copy is preserved and migration pauses without touching legacy files; deletion of an imported item is refused until the ledger is repaired. Corrupt metadata or missing files stay in place with diagnostics.

`ThumbnailService` stores JPEGs under the app sandbox URL returned by `FileManager.urls(for: .cachesDirectory, in: .userDomainMask).first`, in the `ApertureThumbnails` child directory (`Library/Caches/ApertureThumbnails` on iPhone). It has an in-memory limit of 240 images. `ThumbnailCacheKey` includes item ID, processed path, recipe/version/seed, dimensions, requested size, and a version/renderer token; filenames are item-prefixed (`<item-uuid>-<hash>.jpg`) so every size/variant is discoverable after relaunch. The `.aperture-thumbnail-version` marker is written next to the files; a renderer/schema mismatch removes the entire cache before recreation. Item deletion invalidates all matching per-item memory/disk entries across sessions; `clear()` invalidates the whole cache. Bump the cache version when renderer semantics change.

At launch, `AppModel` finds pending or processing items, records an interrupted recoverable failure, and resumes them sequentially (one item at a time) from the original when available, otherwise the processed source. This makes interrupted launches recoverable without a burst of concurrent development work.

## Privacy, permissions, and deletion

Camera authorization is requested for capture; microphone authorization is requested when video mode is selected and is required for recording synchronized sound. `Info.plist` explains both uses and Photos export is add-only, so Aperture does not read the user’s library. `PrivacyInfo.xcprivacy` declares no tracking, no collected data, no off-device collection, and the required UserDefaults accessed-API reason `CA92.1`. Local originals are opt-in (`Preserve Original`); deleting an item removes its committed media directory and thumbnail cache entry. Failed Photos export does not delete or compromise the local item.

## Verification surface

Unit tests cover seeded recipes and output sanity, temporal video decisions, date-stamp geometry, lens mapping/focus normalization, settings and cache keys, storage commit/replacement/deletion/recovery/migration, and reference fixtures. `VideoProcessorTests` exercises deterministic frame treatment, pre-export failures, and a successful file-backed AVAsset render with a playable output; this is Simulator evidence for the renderer only. UI tests cover permission-denied, empty Lab, settings, navigation, and video controls. The simulator cannot provide real camera/microphone hardware, synchronized capture audio, lens switching, flash, thermal/pressure behavior, or reliable Photos behavior; actual capture and captured-media playback/export remain on the physical-device checklist in [docs/release-engineering.md](docs/release-engineering.md).
