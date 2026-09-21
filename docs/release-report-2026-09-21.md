# Overnight release preparation — 2026-09-21

**Status: local engineering verification complete; physical-camera and App Store release gates remain open.** This report records the candidate's engineering evidence. Remote CI/merge and final wireless-install outcomes are recorded in the associated release PR and morning handoff. No App Store submission is authorized by this work.

## Scope and decisions

George requested a two-stage autonomous pipeline: audit against the essentials of Huji's capture/filter/Lab experience, then implement focused fixes and verify release readiness without feature bloat. Subsequent authorization permits verified merges and a final in-place wireless installation on the paired iPhone.

A read-only Fable assessment and three Sonnet domain audits covered product/UX, camera lifecycle/focus/viewfinder, storage/performance, and packaging/release gates. Findings are source-based unless the verification record below says otherwise; competitor comparison uses public descriptions, not firsthand competitor testing. The main session owns integration, tests, review, CI, merge and deployment.

### Kept deliberately unchanged

- The fitted 1998 film response, optics, golden outputs and persisted recipe semantics.
- Full-resolution capture. A proposed 12 MP cap may reduce memory/latency, but changes output quality and needs real-device measurements first.
- The existing three-second tap AF/AE return to continuous focus and bounded dark-flash convergence. Both merit hands-on camera testing; neither was changed based on speculation.
- No cloud sync, account system, social features, monetization, imports, filter packs or broad redesign.

### Selected work

- Camera: transient inactive state versus true background, foreground recording-finish race, truthful permission/preparation copy, stale focus-indicator expiry, overlapping-capture status, modal/hardware-shutter guards and accessible camera chrome.
- Storage/performance: publish the actor's current in-memory snapshot after known durable mutations, while retaining full reconciliation on launch, explicit Lab refresh and uncertain/error paths.
- UI/memory: honest fixed-stamp disclosure for 1998, consistent Lab naming, accessible film sheet, neutral notices, detail-title/video-overlay fixes, byte-cost thumbnail memory budget and bounded detail-media loading.
- Release packaging: dark launch colour, non-exempt-encryption declaration, 1.0.0 (2) candidate metadata, Release compile in CI and retained test/coverage artifacts.
- Launch preparation: [end-to-end checklist](app-store-release-checklist.md), [store copy draft](app-store-metadata-draft.md) and [privacy policy draft](privacy-policy-draft.md). Public URLs, legal/contact details, distribution/account decisions and App Store submission remain separate gates.

## User-visible changes and performance boundaries

- **Camera behavior:** transient inactive transitions no longer voluntarily stop recording; genuine backgrounding still stops safely. Recording navigation/mode guards span startup through the final callback. Foreground completion rechecks whether the session is still wanted rather than blindly stopping/restarting it.
- **Viewfinder feedback:** repeated focus taps cannot be hidden by an older timer. Delayed front-screen flash can be canceled when leaving the camera or opening an obstructing surface. Hardware shutter input respects those surfaces. The physical AF/AE algorithm and flash timing are unchanged pending device evidence.
- **Controls and settings:** camera permission/preparation messages reflect the actual state, large text remains reachable on compact iPhone, the film sheet can expand, and 1998 explains its fixed date stamp instead of offering settings the recipe ignores. The configurable compact stamp is no longer labeled with competitor branding.
- **Lab and detail:** naming is consistent; film titles are human-readable; notices use a neutral information symbol and expire without interrupting VoiceOver. Video captions no longer cover playback controls. Five-item visual verification exposed redundant page dots obscuring the photo caption; the toolbar's existing page count is retained instead.
- **Export correctness:** success reports actual saved and skipped counts. A mixed selection is not misrepresented as a complete backup. Local media stays safe when Photos export fails.
- **Recovery correctness:** once-developed photo/video replacements stay ready after recoverable commit/cleanup errors. They are not offered for accidental double filtering when no original was preserved. Real missing-source/render failures still surface as failures.
- **Memory/work avoidance:** the thumbnail cache accounts for decoded bytes with an advisory **64 MiB / 240-entry** budget, not a hard cap. Detail pages load only the current item and adjacent items, release off-window images/players, and forward cancellation to detached work. No claim of bounded total app memory or preemptible Image I/O is made.
- **Disk work:** successful mutations publish the actor's in-memory index instead of repeatedly reconciling the entire library. Explicit refresh, launch recovery and uncertain outcomes retain reconciliation. No storage format, destructive migration or film-pipeline tuning was introduced.

## Baseline

- Clean starting worktree; release branch `release/app-store-readiness` created from `origin/main` **ca15689**, which includes merged PR #23 (1998 film response). Other existing worktree/session files were preserved.
- Host: Mac mini, Xcode **26.6 (17F113)**, iOS Simulator **26.5 (23F77)**, dedicated iPhone 17 Pro simulator.
- Baseline full suite: **110 passed, 0 failed, 2 skipped** (112 total; 104 passing unit/integration and 6 UI). The two skips are opt-in acceptance-render/date-stamp-preview harnesses, not disabled regressions.
- Baseline app line coverage: **7,449 / 13,252 = 56.21%**. Passing tests must not be described as full code/hardware coverage.
- Baseline denied-camera screen and seeded Lab flow were visually inspected on the simulator.
- Paired target discovery: iPhone 17 Pro, iOS **26.6.2 (23G90)**, Developer Mode enabled, developer disk services available, connected over **localNetwork**. This supersedes older discovery/signing observations in historical release records; it does not establish App Store distribution signing.

## Independent review and additional regressions

A fresh, read-only **Astra (`gpt-6-astra`), high-effort** review covered the changed capture/develop/Lab/settings/export flow, failure paths, storage authority, camera lifecycle, cache/detail behavior, packaging and tests. It found three substantive issues, all accepted for correction before merge:

1. **P1 — authoritative development recovery:** a replacement can already be committed (or recovered from metadata) when manifest/rollback/cleanup reports an error. Marking that ready rendition failed can offer to apply the film a second time when Preserve Original is off. The correction must preserve the authoritative ready item and surface the storage error, with photo/video failure-injection regressions.
2. **P2 — export count:** mixed ready/non-ready selections could report the selected count rather than what Photos actually received. Export now returns actual exported/skipped counts to the local notice; all-non-ready selections remain errors.
3. **P2 — abandoned thumbnail work:** canceling a detail-page task did not cancel its detached renderer. Caller cancellation is now forwarded, checked before new work/encoding/cache publication, and tested with a continuation-controlled gate. Synchronous Image I/O already underway cannot be preempted.

A five-item detail paging regression crosses the current-plus-neighbors preload window in both directions. Parent integration tightened recovery to the actual replacement boundary, required a changed processed path, and corrected the tests' fault timing (the initial fault fired during the preceding processing-state update). It also removed a cancellation-test scheduler race.

The focused **Astra high-effort re-review closed all three findings at source level**, with no concrete remaining production defect in the affected integration paths. The corrected recovery tests passed in the final full suite, alongside the cancellation and export regressions; earlier green runs were not used as evidence for these new failure paths. Actual Photos transactions, physical camera behavior and device-memory measurements remain hardware verification gaps.

## Final verification

Evidence lives under `/tmp/aperture-release-20260921/` on the build host; `.xcresult` bundles and logs are local evidence, not app assets.

- Final full suite (`integration-5.xcresult`): **141 passed, 0 failed, 0 skipped** — **130 unit/integration + 11 UI**, including the new failure-injection and cancellation regressions. All optional acceptance/stamp/snapshot harnesses were explicitly enabled.
- App line coverage: **9,565 / 13,782 = 69.40%**, up from **56.21%** at baseline. This is not 100% coverage; simulator code coverage cannot prove physical camera behavior.
- Compact iPhone SE (3rd generation): **11 UI tests passed**, then the caption/paging regression passed again after hiding redundant dots (`compact-2` and `compact-3`). Main iPhone 17 Pro and compact screenshots were inspected for portrait/landscape controls, largest Dynamic Type, fixed-stamp settings, actual deletion and five-item paging. Images visibly load on page five and after returning to page one; the final date caption is unobstructed. Camera screenshots use an explicitly inert DEBUG fixture, not live capture.
- Full-resolution 12 MP acceptance render and seven-segment stamp preview were generated and inspected. Input was a resized checked-in non-private reference fixture, not newly captured iPhone data. Fitted response probes, golden renders and persisted-recipe compatibility tests passed; the film pipeline and fit data are unchanged.
- Strict-concurrency app build and static analysis (including test compilation): **passed**, with `SWIFT_STRICT_CONCURRENCY=complete` and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- Unsigned Release archive and packaging inspection: **passed**. Version **1.0.0 (2)**, existing bundle/team, iPhone-only iOS 17 target, arm64 executable, matching dSYM UUID, app icon, exact named Ink launch colour, permission text and privacy manifest verified. DEBUG preview-fixture and Timing UI strings are absent from the Release executable. This does not validate distribution signing.
- Latest simulator snapshot microbenchmark: 100 tiny committed items, 20 iterations per path. `currentSnapshot()` averaged **0.576 ms** versus **32.297 ms** for full reconciliation. This is a bounded FileManager/index workload, not a claim about total shutter/development time or physical-iPhone speed.
- Local engineering gates are complete. Remote CI/merge and the authorized final wireless handoff are subsequent delivery steps; their observed outcomes belong in the associated PR and morning handoff, not this pre-commit evidence record.

## Physical and production gates

The simulator cannot establish real autofocus accuracy, image quality, lens/flash transitions, camera/audio synchronization, thermal pressure, captured-media playback/export or iPhone latency/memory. Keep those gates open until exercised. A successful wireless install/launch is not a physical-camera test pass.

Apple requires a privacy-policy URL for **all** apps, including apps declaring no data collection, plus a functional support link and review contact. Owner-reviewed/publicly hosted policy and support pages, in-app policy access, TestFlight, signed distribution validation, store metadata, rights/age-rating/trader/compliance decisions, and explicit submission/public-release authorization are required before calling this App Store ready.

## Research sources

- [Huji Cam App Store listing](https://apps.apple.com/us/app/huji-cam/id781383622)
- [Digital Camera World — Huji experience](https://www.digitalcameraworld.com/tech/apps/this-free-disposable-camera-app-is-wildly-unpredictable-but-thats-100-percent-why-its-my-favorite-way-to-take-photos-on-my-phone)
- [Apple App Privacy — policy URL required for all apps](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy)
- [Apple SDK upload requirement effective April 28, 2026](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
- [Apple App Review preparation](https://developer.apple.com/app-store/review/)
