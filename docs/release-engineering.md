# Release engineering

## Build and test commands

```sh
# Simulator compile
xcodebuild -project Aperture.xcodeproj -scheme Aperture \
  -sdk iphonesimulator -configuration Debug build

# Unit + UI tests on a named simulator
xcodebuild -project Aperture.xcodeproj -scheme Aperture \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test

# Unsigned device compile check
xcodebuild -project Aperture.xcodeproj -scheme Aperture \
  -sdk iphoneos -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

The project targets iOS 17.0, Swift 5, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), bundle ID `com.georgenijo.Aperture`, and has Debug/Release configurations. A signed physical-device run still requires a valid Xcode team/profile. Keep the Xcode version and SDK used for release consistent with the device fleet.

## Coverage boundaries

Simulator: deterministic recipes (including temporal video decisions), Core Image output, storage transactions/recovery/migration, settings/cache behavior, and UI states using `-ui-test-camera-denied` / `-ui-test-empty-library`. `VideoProcessorTests` covers deterministic treatment, pre-export failures, and a successful generated file-backed AVAsset render with a playable output. That is renderer/export-path evidence only; it does not prove camera capture, microphone input or synchronized audio, thermal/pressure behavior, or playback fidelity for captured media.

Physical iPhone: actual photo and up-to-60-second film capture, microphone permission and synchronized audio track, camera/session lifecycle, lens discovery and transitions, focus/exposure, flash, responsive/zero-shutter-lag behavior, thermal and device pressure, interruptions, orientation, AVAsset development/playback for captured media, Photos add-only export, and real capture latency. The simulator cannot prove these hardware and capture gates.

Paired iPhone verification may be blocked by an Xcode/device developer disk image or toolchain mismatch. Record the exact Xcode version, iOS build, device model, and error; do not convert a blocked run into a passing release gate.

## Current verification record — 2026-09-15

- Xcode 26.6 (17F113), iOS 26.5 Simulator: strict Swift concurrency type-check, clean Debug build, static analysis, and all 57 tests passed (53 unit/integration plus 4 UI).
- Generic iOS device: unsigned Release build and unsigned Release archive both succeeded; the archive contains the arm64 app, dSYM, app icon, permission strings, and `PrivacyInfo.xcprivacy`.
- Signed archive: blocked because this Mac has no usable Apple developer account credentials or provisioning profile for `com.georgenijo.Aperture`.
- Paired iPhone 17 Pro on iOS 26.6.2: destination discovery succeeded, but the developer disk image could not be mounted, so install/launch and the physical checklist remain open.

### Physical-device record — 2026-09-15 (Shawn's Mac)

- Xcode 26.6 (17F113), iOS 26.5 Simulator, commit `2d357ff`: all 63 tests passed (59 unit/integration plus 4 UI).
- Paired iPhone 15 Pro (`iPhone16,1`, 128 GB) on iOS 27.0 (24A437), Developer Mode enabled: developer disk image mounted, signed Debug build installed and launched. Signing used a Personal Team with a dev bundle ID override (`DEVELOPMENT_TEAM`/`PRODUCT_BUNDLE_IDENTIFIER` via a local xcconfig, not committed); a signed archive under the project's team is still open.
- All 59 unit/integration tests passed on the iPhone itself, including the `FilmProcessorTests`, `ReferenceFixtureTests`, and `VideoProcessorTests` renderers on device hardware. One test needed a device-portability fix: on device `contentsOfDirectory` returns `/private/var/...` while the library returns the symlink-resolved `/var/...` form, so `MediaLibraryTests` now compares resolved paths. Production code only compares relative paths and `lastPathComponent`, so no library change was needed.
- UI tests on device: blocked. The free developer profile allows three installed apps per device and the `ApertureUITests-Runner` was the fourth (`MIInstallerErrorDomain` code 13). UI coverage stands on the simulator run only.
- Interactive checklist items below (permissions, capture, lens/flash, recording, Photos export) still need a person holding the device; the installed build is ready for that pass.

## Performance targets and measurement status

Targets are release gates to measure, not current claims: shutter tap should return control without waiting for development; camera/session UI should remain responsive during repeated captures; the local commit should complete before development begins; pending/processing media should resume sequentially after an interrupted launch; and representative full-resolution/photo or short-film development should complete without memory pressure or dropped camera responsiveness. The repository currently has no recorded device benchmark baseline. Capture baseline timings and memory/pressure observations on representative physical devices before declaring targets passed.

Measure with Instruments/OSLog signposts or timestamped test notes around: shutter request, photo delegate completion, media commit, processing start/end, processed replacement, and Lab refresh. Record image dimensions, recipe, device, OS, build, warm/cold state, median and p95 latency, failures, and peak memory/pressure. Do not optimize by re-enabling deferred proxy delivery without revisiting the fidelity and commit contract.

## Physical-device verification checklist

### Before installing

- [ ] Confirm signed Release (or a signed Debug build) installs on each target iPhone.
- [ ] Record device model, iOS version, available storage, Xcode version, build commit, and camera configuration.
- [ ] Start from a clean install only when testing first-run permissions; preserve an upgrade install for migration/recovery checks.

### Permissions and lifecycle

- [ ] Deny camera access: the app explains the state and does not attempt capture; Settings recovery works.
- [ ] Grant camera access: preview starts, stops when leaving camera, and restarts after returning.
- [ ] Select Video and grant microphone access; verify denial explains that synchronized sound is required and Settings recovery works.
- [ ] Background/foreground during preview and during development; verify no stuck spinner or lost committed item.
- [ ] Exercise phone call, interruption, lock/unlock, and media-services reset recovery where practical.

### Capture and camera behavior

- [ ] Capture repeated rear-camera stills in portrait and landscape; verify every shutter produces one Lab item.
- [ ] Switch front/rear and capture; verify orientation, metadata, and preview remain correct.
- [ ] Visit every discovered lens stop, ramp between stops, and confirm the selected display stop matches the physical device’s available cameras.
- [ ] Tap near each preview corner and center; verify focus/exposure feedback and no crash on unsupported points.
- [ ] Test Auto/On/Off flash in bright and dark scenes; record unsupported-device behavior.
- [ ] Test low light, high contrast, moving subjects, and repeated rapid shutter taps.
- [ ] Observe pressure/runtime interruption messaging and confirm recovery without corrupting the Lab.
- [ ] Record short films with sound, stop manually, and let one reach the 60-second cap; verify each clip becomes one pending Lab item.
- [ ] Background/interrupt during recording; verify the clip closes safely, audio is preserved, and development can finish or retry.

### Development, storage, and privacy

- [ ] Confirm a pending item is committed before development and that retry works after a forced/observed failure.
- [ ] Compare repeated development of the same item: output must be deterministic from its persisted recipe/seed.
- [ ] Check each recipe, light-leak toggle, date-stamp mode, and preserved-original setting. For 1998, confirm the seven-segment orange stamp sits along the left edge of a portrait capture reading bottom-to-top (bottom-right, unrotated, for landscape), and that its light leaks only enter from the top or right edge.
- [ ] Change Photo Quality after capture, retry/re-develop the item, and verify the persisted JPEG compression quality is used rather than the new setting (Balanced now resolves to 0.92).
- [ ] Inspect a developed JPEG's metadata (e.g. `exiftool`): capture EXIF/TIFF fields are retained, orientation reads as upright, pixel dimensions match the rendered output, and no embedded thumbnail is present. Image I/O offers no switch for 4:4:4 chroma subsampling, so do not gate on it.
- [ ] Enable a date stamp for a short film and verify the same persisted date-stamp overlay remains stable across its frames.
- [ ] Interrupt an install with pending/processing items, relaunch, and verify development resumes sequentially without duplicate or lost Lab items.
- [ ] Verify video development keeps color/light-leak treatment static while grain evolves deterministically by frame; verify output is playable with its audio track.
- [ ] Fill storage or simulate write failure where safe; verify a clear error and no half-committed visible item.
- [ ] Upgrade an install containing legacy `Documents/photos` data; verify import once and legacy files remain untouched.
- [ ] Delete an imported legacy item; verify `legacy-deletions.json` is written atomically, the untouched legacy source remains present, and the tombstone prevents re-import after relaunch.
- [ ] Corrupt `legacy-deletions.json` in a controlled test; verify the backup is preserved in `recovery/`, migration pauses without touching legacy files, and imported-item deletion is refused until repair.
- [ ] Force or simulate a replacement/index failure; verify the prior committed asset remains usable, uncertain rollback retains recoverable media, and relaunch reconciliation removes only safe orphans.
- [ ] Delete single and multiple items; confirm media and thumbnails disappear and unrelated items remain.
- [ ] Verify thumbnail files use the item-prefixed discoverable naming scheme, per-item deletion removes all prior-session variants, and changing the renderer marker/version performs full cache invalidation.
- [ ] Verify no network/account prompt and that originals remain local unless the user exports.

### Photos and handoff

- [ ] Export one and multiple developed stills with Photos access granted.
- [ ] Test add-only denied, limited, and revoked states; local Lab items must remain safe.
- [ ] Test share from Lab and detail view.
- [ ] Play a developed film in detail view, scrub/replay it, share it, and export it to Photos.

### Release evidence

- [ ] Run simulator unit/UI tests on the release commit.
- [x] Record the successful generated file-backed AVAsset render test as Simulator renderer evidence only.
- [ ] Keep the physical-device capture/audio/thermal/lens/flash gates open until checked.
- [ ] Attach device logs/screenshots and latency/memory notes to the release record.
- [ ] Verify version/build number, icon, permission strings, privacy copy, and archive validation.
- [ ] Verify `PrivacyInfo.xcprivacy` is included in the app resource bundle and declares the intended UserDefaults access reason with no tracking/collected data.
- [ ] Verify the privacy manifest records UserDefaults reason `CA92.1`, no tracking, and no off-device collection; verify camera/microphone strings match actual capture behavior.
- [ ] Confirm all pending ROADMAP items—especially video—remain accurately described in user-facing materials.
