# Aperture roadmap

Status is based on the source in this repository, not on the data model’s future-facing seams.

## Implemented in v1

- Still capture with front/rear camera switching, focus/exposure taps, flash modes, ramped zoom, discovered lens stops, interruption/pressure handling, and responsive capture features where supported.
- Local Lab with deterministic 1998/Night/Cinema development, optional original retention, retries, Favorites, share, add-only Photos export, deletion, cache invalidation, recovery, and legacy import. Legacy deletion tombstones are durable and a corrupt ledger pauses migration without touching source files; replacement failures retain recoverable media for launch-time reconciliation.
- Unit/reference-fixture tests and simulator UI coverage for denied camera access, empty Lab, settings, and navigation. `VideoProcessorTests` covers deterministic frame treatment, pre-export failures, and a successful generated-file AVAsset render with a playable output.

## Still-photo work remaining before release

- Complete physical-device verification across supported iPhone generations, rear/front cameras, available lens configurations, orientation, flash, low light, storage pressure, interruption, and repeated capture.
- Establish measured capture-to-commit and development latency baselines for representative image sizes; document results and investigate regressions.
- Validate add-only Photos export and auto-save with granted, denied, limited, and revoked permissions.
- Decide supported OS/device matrix and complete signed Release/archive, install, launch, upgrade, and recovery checks.
- Review accessibility labels, privacy strings, app icon, crash logging policy, and App Store metadata.

## Pending, not implemented

- Cloud sync, accounts, social features, monetization, and additional recipe/asset systems.

## Video release work remaining

- Complete physical-device verification of actual capture, recording duration cap, microphone permission and audio-track synchronization/preservation, interruption/foreground behavior, orientation, playback, share, and Photos export. Also verify thermal/pressure behavior and device-specific lens/flash behavior; simulator rendering cannot close these gates.
- Establish measured short-clip processing and memory baselines; no performance numbers are claimed until measured.

Do not claim any pending item exists until its capture path, UI, storage behavior, tests, and release verification are present.
