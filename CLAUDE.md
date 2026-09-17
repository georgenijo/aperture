# Aperture contributor notes

Aperture is a native Swift/SwiftUI iOS 17+ iPhone camera for stills and short films. Apple frameworks own the runtime: AVFoundation capture/movie recording, Core Image/Image I/O development, FileManager storage, Photos add-only export, and XCTest/XCUITest verification. There are no third-party packages.

## Commands

```sh
xcodebuild -project Aperture.xcodeproj -scheme Aperture -sdk iphonesimulator -configuration Debug build
xcodebuild -project Aperture.xcodeproj -scheme Aperture -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
xcodebuild -project Aperture.xcodeproj -scheme Aperture -sdk iphoneos -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

The last command is an unsigned compile check; running the camera requires a signed physical-device build. The project has `Aperture`, `ApertureTests`, and `ApertureUITests` targets and one shared `Aperture` scheme.

## Where code lives

- `Aperture/CameraManager.swift` and `Aperture/Camera/`: serialized AVFoundation session/configuration, photo/movie delegates, microphone input, capabilities, zoom/lens mapping, focus/exposure, interruptions, and pressure handling.
- `Aperture/App/`: `AppModel`, the main actor boundary between camera, storage, processing, settings, thumbnails, and export.
- `Aperture/Processing/`: versioned `FilmRecipe` values and deterministic Core Image rendering. `FilmResponse.swift` is the fitted colour stage the 1998 recipe uses; its numbers come from `tools/film-response-fit/` (Python, offline) and must stay in sync with `ApertureTests/Fixtures/film-response-probes.json`.
- `Aperture/Storage/`: actor-isolated media library, atomic staging/commit/replacement/deletion, recovery, legacy migration and its durable deletion ledger, settings, and cache keys.
- `Aperture/UI/`, root SwiftUI views, and `CameraPreview.swift`: camera, Lab, detail, settings, and styling.
- `ApertureTests/` and `ApertureUITests/`: unit/integration and permission-denied/empty-library UI coverage.

## Invariants

- All AVFoundation graph, device, output, connection, and capture mutations use the dedicated user-initiated camera queue. Published state is delivered to the main actor.
- A capture is staged and committed before Core Image development starts. The UI can therefore show a pending item and recover/retry after interruption.
- Rendering consumes the persisted applied recipe (including seed, date-stamp text, and timezone), never current settings/date/random state. Reuse the singleton `CIContext`; do not create one per image.
- `Photo Quality` is resolved at capture time into the recipe’s persisted JPEG compression quality; re-development must use that snapshot rather than current Settings.
- On launch, pending/processing items are marked interrupted and resumed one at a time in capture order, yielding between items to bound CPU, memory, and disk pressure.
- Media paths are validated relative paths under the library root. Writes use temporary/staging locations and atomic metadata writes.
- Legacy migration records deleted imported identifiers in `legacy-deletions.json` with an atomic write. If that ledger is missing, invalid, or cannot be preserved for recovery, migration pauses without touching legacy files; deleting an imported item is also refused until the ledger is available again.
- Processed-asset replacement publishes a new asset and metadata before removing superseded files. If metadata rollback is uncertain, the new media is retained for launch-time reconciliation; reconciliation removes orphans only after every metadata-referenced asset is confirmed present.
- Derived thumbnails use item-prefixed, discoverable filenames. The `.aperture-thumbnail-version` marker invalidates the complete disk cache when the renderer/schema token changes; per-item invalidation works across relaunches.
- Video is real shipped code: `AVCaptureMovieFileOutput` records a microphone-backed `.mov` to a temporary URL, capped at 60 seconds; `VideoProcessor` develops it before the processed asset is committed.
- The target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`); do not describe iPad support.

See [the implemented architecture](film-camera-app-architecture.md) and [release gates](docs/release-engineering.md) before changing capture or storage behavior.
