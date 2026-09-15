<picture><source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.svg"><img src="docs/banner.svg" alt="aperture — iOS film camera" width="100%"></picture>

# Aperture

A native iOS still camera with a small, deliberate film vocabulary: responsive capture, camera-style lens stops, local development, and a private Lab for the resulting photographs.

## Current v1

- SwiftUI shell with AVFoundation capture/movie recording and UIKit camera preview.
- Rear/front camera switching, tap focus/exposure, flash modes, ramped zoom, and device-dependent lens stops.
- Three built-in recipes: 1998, Night, and Cinema; seeded grain, halation, warmth, vignette, chromatic aberration, optional light leak, and date stamp.
- Photo Quality is captured into each applied recipe as a JPEG compression quality, so re-development remains reproducible after Settings change.
- Capture bytes are committed locally before development. Development is deferred off the camera/session path and can be retried.
- Photo mode and short-film mode (with synchronized microphone audio), capped at 60 seconds per clip. Developed films play in detail view and can be shared/exported to Photos.
- App-sandbox media library, optional original preservation, Favorites, share/export, deletion, thumbnail cache, recovery, and legacy `Documents/photos` migration. Legacy deletions are kept in a durable tombstone ledger; a corrupt ledger pauses migration safely.
- No accounts, analytics, ads, or uploads. Camera and microphone are used only for capture; Photos export uses add-only permission.

Video processing uses a file-backed movie input and a temporally stable Core Image treatment. A generated tiny-movie test exercises successful rendering and validates a playable output in Simulator; actual capture, microphone/audio sync, thermal/pressure behavior, lens/flash behavior, and playback/export on captured media remain physical-device release gates. See [release engineering](docs/release-engineering.md).

## Build and test

```sh
xcodebuild -project Aperture.xcodeproj -scheme Aperture \
  -sdk iphonesimulator -configuration Debug build
xcodebuild -project Aperture.xcodeproj -scheme Aperture \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

The simulator can cover UI, storage/recovery/migration, recipes, and deterministic processing. Camera capture, microphone/audio sync, thermal/pressure behavior, flash, lens availability, and Photos export of captured media require a physical iPhone. See [release engineering](docs/release-engineering.md).

## Documentation

- [Architecture](film-camera-app-architecture.md)
- [Release engineering and device checklist](docs/release-engineering.md)
- [Roadmap](ROADMAP.md)
- [Historical research and build context](huji-cam-research-and-build-guide.md)
- [Contributor notes](CLAUDE.md)
