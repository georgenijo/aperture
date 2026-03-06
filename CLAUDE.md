# CLAUDE.md

Native iOS camera app with vintage film emulation. Swift + SwiftUI, AVFoundation camera, Core Image + Metal processing pipeline. Film stocks, light leaks, grain, date stamps — the Huji aesthetic with pro camera controls.

## Commands

```bash
# Build (CLI, no signing — for verification)
xcodebuild -project Aperture.xcodeproj -target Aperture -sdk iphoneos -configuration Debug build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

# Deploy to device — open Aperture.xcodeproj in Xcode, select your iPhone, hit Run
```

## Docs

Read these before working on a feature:

- **[film-camera-app-architecture.md](film-camera-app-architecture.md)** — Full technical architecture: camera engine, processing pipeline, storage, UI, development phases
- **[huji-cam-research-and-build-guide.md](huji-cam-research-and-build-guide.md)** — Huji reverse-engineering, competitive landscape, image processing details, tech stack analysis

## File Map

### App (`Aperture/`)

| File | Purpose |
|------|---------|
| `ApertureApp.swift` | App entry point, SwiftUI lifecycle |
| `ContentView.swift` | Root view — camera preview, shutter button, permission handling |
| `CameraManager.swift` | AVFoundation session, photo capture (HEVC/JPEG), delegate handling |
| `CameraPreview.swift` | UIViewRepresentable wrapping AVCaptureVideoPreviewLayer |
| `PhotoStorage.swift` | Saves photos + JSON metadata to Documents/photos/ |
| `Assets.xcassets` | Asset catalog (app icon, accent color) |
| `Info.plist` | Camera permission (NSCameraUsageDescription) |

## Architecture Decisions

- **iOS 17+** — enables latest SwiftUI and AVFoundation APIs
- **SwiftUI** for app shell, **UIKit** (via UIViewRepresentable) for camera preview layer
- **AVFoundation** for camera capture — AVCaptureSession, AVCapturePhotoOutput
- **Core Image + Metal** for the film processing pipeline (future)
- **App sandbox storage** for photos — no Photos framework dependency until export feature
- **No third-party dependencies** — Apple frameworks only unless we hit a wall

## iOS Gotchas

- Camera only works on a real device — the simulator has no camera hardware
- `CIContext` is expensive to create (~50ms) — create once, reuse everywhere
- `AVCaptureSession` configuration changes must be wrapped in `beginConfiguration()`/`commitConfiguration()`
- Always query `AVCaptureDevice.DiscoverySession` for available lenses — not all iPhones have the same cameras
- High-res photos can be 12-48MP — use `CIImage` (lazy evaluation) through the pipeline, only render to `CGImage` at the final output step
- `AVCapturePhotoSettings.photoQualityPrioritization` must not exceed `photoOutput.maxPhotoQualityPrioritization` or it crashes
- `.quality` prioritization triggers Deep Fusion (~800ms on iPhone 15 Pro Max) — lock the shutter button during capture
- Camera startup (`session.startRunning()`) blocks for ~300ms — this is normal hardware spin-up

## Project Config

- **Bundle ID**: `com.georgenijo.Aperture`
- **Team**: `P2U3P8B923`
- **Deployment target**: iOS 17.0
- **Signing**: Automatic
