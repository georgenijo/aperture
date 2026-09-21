# App Store release checklist

This is the production runbook for Aperture, an iPhone-only iOS 17+ camera. A green PR is **not** an App Store release. Use this alongside [release engineering](release-engineering.md), which contains the capture, recovery, export and physical-device matrix. Check boxes only with evidence for the exact release revision.

## 1. Product and scope

- [ ] Still capture → local commit → deterministic development → Lab → detail/share/export works end to end on a physical iPhone.
- [ ] Existing short-film recording works with synchronized microphone audio, manual stop and the 60-second cap. Do not describe video as a future feature.
- [ ] 1998, Night and Cinema are visually checked; old persisted recipes still re-develop identically. Do not change fitted colour constants to make performance tests pass.
- [ ] Settings describe actual behavior: 1998 includes its fixed compact current-date stamp; other films use the configurable stamp. Full-screen viewfinder crops the preview, not the captured asset.
- [ ] No competitor branding, copied artwork, invented capabilities, or claims of iPad support in the product or store listing.
- [ ] No new accounts, network services, analytics, advertising, subscriptions or in-app purchases are needed for this release.

## 2. Automated release gates

- [ ] Clean checkout of the proposed release SHA; record Xcode, SDK, OS, version and build number.
- [ ] Full simulator unit/integration/UI suite passes. Record passed, failed and skipped totals, not merely the exit code.
- [ ] Collect app line coverage and affected-path regression evidence. A passing suite is not 100% coverage and simulator tests do not cover physical AVFoundation behavior.
- [ ] UI flows include denied permissions, empty/seeded Lab, actual deletion, detail paging, settings, film selection, portrait/landscape, compact iPhone and largest Dynamic Type.
- [ ] Golden renders, fitted-response probes, persisted recipes, export metadata, migration/deletion ledger, recovery/rollback and video renderer tests pass.
- [ ] Optional acceptance-render and date-stamp preview harnesses run explicitly when preparing visual evidence; record their environment variables and input provenance. Never upload personal reference photos as CI artifacts.
- [ ] Strict-concurrency Debug build, static analysis and unsigned Release device build pass.
- [ ] Release archive includes arm64 executable, dSYM, app icon, launch colour, permission strings and `PrivacyInfo.xcprivacy`.
- [ ] Fresh independent Astra (`gpt-6-astra`, high effort) review covers full changed user flows, failure paths and integration; confirmed defects resolved.
- [ ] Latest PR revision has passing CI and is mergeable. Verify remote merge SHA. Admin merge is only for an otherwise verified PR; do not bypass failed checks or weaken protections.

CI preserves `.xcresult` test/coverage evidence and also compiles unsigned Release for iPhone. CI must not install anything on a personal phone.

## 3. Physical iPhone and performance gates

Complete the detailed checklist in [release engineering](release-engineering.md). At minimum:

- [ ] Preserve an upgrade install with real local media; use a separate clean install/device for first-run permission testing. Never uninstall the user's app as a deployment workaround.
- [ ] Camera/microphone denial, Settings recovery, Photos add-only denial/revocation and export failures are understandable and retain local media.
- [ ] Rear/front captures, lens stops/zoom, tap focus in preview corners, AF/AE recovery, flash Auto/On/Off and front screen flash work in portrait/landscape.
- [ ] Rapid captures produce exactly one committed item per accepted shutter; no image loss, duplicate development, stuck readiness or stale pending state.
- [ ] Control Center/transient inactive state does not voluntarily end recording; genuine backgrounding/interruption closes the clip safely. AVFoundation/system interruptions may still stop capture.
- [ ] Hardware shutter is disabled under film/flash/error surfaces; iOS 17's on-screen-only shutter limitation is accurately described.
- [ ] Short video and 60-second cap preserve audio synchronization; developed output plays, seeks, shares and exports. Check camera switching, background/foreground, calls and media-services recovery.
- [ ] Low storage, pending-item relaunch, retry, deletion, legacy migration and uncertain rollback are exercised safely on test data.
- [ ] Measure cold/warm launch-to-preview, shutter-to-camera-result, commit, development, Lab opening and scrolling with representative library sizes and photo dimensions.
- [ ] Record median/p95 timings, sample count, device/OS/build, image size/recipe, peak memory and thermal/pressure observations. A simulator FileManager benchmark is not an iPhone shutter benchmark.
- [ ] Measure on a lower-memory supported iPhone as well as a current Pro. Keep full-resolution capture unchanged until evidence justifies a deliberate quality/performance trade-off.

## 4. Signing, packaging and compliance

- [ ] Confirm Apple Developer Program membership, distribution team, agreements and App Store Connect access. Existing development signing does not prove distribution signing.
- [ ] Register/select the existing bundle ID `com.georgenijo.Aperture`; do not change the bundle ID/team to work around provisioning failures.
- [ ] Choose the release version/build; repository candidate is `1.0.0 (2)`. Ensure the build number exceeds any prior uploaded build for this version.
- [ ] Use Xcode 26+ and the iOS 26+ SDK for App Store uploads (Apple's requirement effective April 28, 2026). The deployment target may remain iOS 17.
- [ ] Create a signed distribution archive, validate in Organizer/App Store Connect, and resolve all validation warnings/errors. An unsigned archive is compile/packaging evidence only.
- [ ] Confirm `ITSAppUsesNonExemptEncryption = NO` remains correct: the app currently implements no custom/non-exempt encryption. Reassess if networking/crypto features are added.
- [ ] Validate privacy manifest: no tracking, no off-device data collection, UserDefaults reason `CA92.1`, and no undeclared required-reason API usage. Check the archive's privacy report, not just the source file.
- [ ] Confirm camera, microphone and Photos-add usage strings match actual behavior. Do not request Photos read/location/contacts permissions.
- [ ] Check icon transparency/dimensions, dark launch appearance, iPhone family/orientations, supported OS/device coverage and absence of debug fixture/Timing UI in Release.

## 5. App Store Connect and public pages

These require owner/account/legal decisions. Repository drafts are not published pages.

- [ ] Create/update the app record, primary language, category, copyright, availability/regions and price. No pricing/business model is assumed here.
- [ ] Finalize app name, subtitle, description, promotional text and keywords without competitor trademarks or unsupported claims.
- [ ] Provide real screenshots at Apple's currently accepted iPhone display sizes. Do not submit simulator placeholder-camera screens as live-camera marketing evidence.
- [ ] Complete current age-rating questionnaire, content-rights questions, export compliance and EU trader-status requirements where applicable.
- [ ] Complete App Privacy answers: no data collected only after confirming the shipped binary and all dependencies. Local processing and OS-managed backups are not an app-operated upload service.
- [ ] Publish an owner-reviewed privacy policy and functional support page with current contact information, using Family Host unless another destination is chosen.
- [ ] Set **Privacy Policy URL for every app, including no-data-collection apps**, and Support URL. Add an easily accessible in-app privacy-policy link. Marketing URL is optional.
- [ ] Set app-review contact details, review notes explaining physical-camera/microphone requirements and permission recovery, and any required attachments. No demo account is needed for an account-free app.
- [ ] Confirm store privacy text agrees with local originals, exports/shares, deletion and system backups. Review [privacy-policy draft](privacy-policy-draft.md) before publishing.

## 6. TestFlight, submission and production

- [ ] Upload validated signed build and wait for App Store Connect processing; resolve compliance or processing issues.
- [ ] Test the actual TestFlight build on representative iPhones. Verify fresh install and upgrade with preserved media, all camera/export flows and the build number shown in Settings.
- [ ] Review TestFlight crash reports/feedback and establish a short regression pass on the final candidate.
- [ ] Obtain explicit authorization for App Store submission and public release. Permission to merge or install on a personal phone is not permission to submit/publish.
- [ ] Submit the selected build with complete metadata; answer reviewer requests honestly.
- [ ] Choose manual/automatic release intentionally. Phased release applies to updates, not the first public release.
- [ ] After approval, verify the live App Store listing, support/privacy URLs, screenshots, version and a store-installed copy.
- [ ] Monitor App Store Connect crash/feedback signals and support reports. Keep the release SHA/archive/dSYM and a hotfix branch path; reverting source does not downgrade an already-installed iOS app.
- [ ] For a severe launch issue, stop an update's phased rollout where applicable or remove availability as authorized; deliver a corrected higher-build update without destructive storage migration.

## 7. Authorized in-place wireless handoff

Only after all engineering work is integrated:

1. Verify the final merged SHA and CI, paired target device, existing bundle ID and signing team.
2. Build that revision with the existing signing setup. Keep build products outside the repository.
3. Install **over** the existing app via `devicectl`; never uninstall or reset its container.
4. Launch if the device is unlocked. A locked-device launch failure must be reported separately from a successful install.
5. Record installed version/build and process launch result; leave the physical-camera checklist open until actually exercised.

## Sources (checked 2026-09-21)

- [Apple SDK minimum requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
- [Apple App Privacy fields — privacy policy URL required for all apps](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy)
- [Apple App Review preparation](https://developer.apple.com/app-store/review/)
- [Apple privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Apple encryption export documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
