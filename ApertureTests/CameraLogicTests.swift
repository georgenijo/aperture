import CoreGraphics
import XCTest

@testable import Aperture

final class CameraLogicTests: XCTestCase {
  func testLensOptionsClampToSensibleDisplayMaximumAndDeduplicate() {
    let options = LensOptionMapper.options(
      minimumRawZoom: 1,
      maximumRawZoom: 30,
      switchOverFactors: [2, 2.01, 5],
      secondaryNativeFactors: [3, 5.02, 12],
      displayMultiplier: 0.5,
      sensibleMaximumDisplayZoom: 10
    )

    XCTAssertEqual(options.map(\.rawZoomFactor), [1, 2, 3, 5, 12])
    XCTAssertTrue(options.allSatisfy { $0.displayZoomFactor <= 10 })
  }

  func testLensOptionsIgnoreInvalidAndBelowMinimumFactors() {
    let options = LensOptionMapper.options(
      minimumRawZoom: 0.5,
      maximumRawZoom: 8,
      switchOverFactors: [.nan, -.infinity, 0, 1.99],
      secondaryNativeFactors: [.infinity, -1, 2.1],
      displayMultiplier: 0.5
    )

    XCTAssertEqual(options.map(\.rawZoomFactor), [0.5, 1.99, 2.1])
    XCTAssertTrue(options.allSatisfy { $0.rawZoomFactor >= 0.5 && $0.displayZoomFactor <= 10 })
  }

  func testLensOptionsDoNotInventAButtonAtTheProductZoomCeiling() {
    let options = LensOptionMapper.options(
      minimumRawZoom: 1,
      maximumRawZoom: 30,
      switchOverFactors: [2, 5, 25],
      secondaryNativeFactors: [20.5],
      displayMultiplier: 0.5,
      sensibleMaximumDisplayZoom: 10
    )

    XCTAssertEqual(options.map(\.rawZoomFactor), [1, 2, 5])
    XCTAssertFalse(options.contains { $0.rawZoomFactor == 20 })
  }

  func testZoomClampHandlesFiniteBounds() {
    XCTAssertEqual(
      LensOptionMapper.clamp(rawZoomFactor: -2, minimumRawZoom: 1, maximumRawZoom: 8), 1)
    XCTAssertEqual(
      LensOptionMapper.clamp(rawZoomFactor: 12, minimumRawZoom: 1, maximumRawZoom: 8), 8)
    XCTAssertEqual(
      LensOptionMapper.clamp(rawZoomFactor: 4, minimumRawZoom: 1, maximumRawZoom: 8), 4)
    XCTAssertEqual(
      LensOptionMapper.clamp(rawZoomFactor: .nan, minimumRawZoom: 0.5, maximumRawZoom: 0.8), 0.5)
  }

  func testFocusPointIsNormalizedAndInvalidValuesReturnCenter() {
    XCTAssertEqual(
      LensOptionMapper.normalizedFocusPoint(CGPoint(x: -0.2, y: 2)), CGPoint(x: 0, y: 1))
    XCTAssertEqual(
      LensOptionMapper.normalizedFocusPoint(CGPoint(x: CGFloat.infinity, y: CGFloat.nan)),
      CGPoint(x: 0.5, y: 0.5)
    )
  }

  func testCameraFocusEventClampsViewAndDevicePointsIndependently() {
    let event = CameraFocusEvent(
      viewPoint: CGPoint(x: -1, y: 0.4), devicePoint: CGPoint(x: 1.2, y: 0.6))

    XCTAssertEqual(event.viewPoint, CGPoint(x: 0, y: 0.4))
    XCTAssertEqual(event.devicePoint, CGPoint(x: 1, y: 0.6))
  }

  func testFrontOnFlashUsesScreenFlashButPreservesIntentInMetadata() {
    let decision = CameraFlashLogic.decision(requested: .on, position: .front, supportedModes: [])

    XCTAssertEqual(decision.avMode, .off)
    XCTAssertEqual(decision.metadataMode, .on)
    XCTAssertTrue(decision.usesScreenFlash)
  }

  func testRearFlashFallsBackToOffWhenCapabilityIsMissing() {
    let decision = CameraFlashLogic.decision(
      requested: .on, position: .back, supportedModes: [.auto])

    XCTAssertEqual(decision.avMode, .off)
    XCTAssertEqual(decision.metadataMode, .off)
    XCTAssertFalse(decision.usesScreenFlash)
  }

  func testRearFlashRetainsSupportedRequestedMode() {
    let decision = CameraFlashLogic.decision(
      requested: .auto, position: .back, supportedModes: [.auto, .on, .off])

    XCTAssertEqual(decision.avMode, .auto)
    XCTAssertEqual(decision.metadataMode, .auto)
    XCTAssertFalse(decision.usesScreenFlash)
  }

  func testFlashOnIsOfferedOnlyWhereItCanBeFulfilled() {
    XCTAssertEqual(
      CameraFlashLogic.availableModes(hasFlash: true, position: .back), CameraFlashMode.allCases)
    XCTAssertEqual(CameraFlashLogic.availableModes(hasFlash: false, position: .front), [.off, .on])
    XCTAssertEqual(CameraFlashLogic.availableModes(hasFlash: false, position: .back), [.off])
  }

  func testCompletedRecordingDurationFallsBackToWallClockWhenOutputReportsZero() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let startedAt = now.addingTimeInterval(-3)

    XCTAssertEqual(
      CameraRecordingLogic.completedDuration(recordedSeconds: 2.5, startedAt: startedAt, now: now),
      2.5)
    XCTAssertEqual(
      CameraRecordingLogic.completedDuration(recordedSeconds: 0, startedAt: startedAt, now: now), 3)
    XCTAssertEqual(
      CameraRecordingLogic.completedDuration(recordedSeconds: .nan, startedAt: startedAt, now: now),
      3)
    XCTAssertEqual(
      CameraRecordingLogic.completedDuration(recordedSeconds: 0, startedAt: nil, now: now), 0)
  }

  func testSessionResumesAfterASystemStopOnlyWhileTheUIStillWantsIt() {
    XCTAssertTrue(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: true, isRunning: false, isInterrupted: false, isRecording: false))
    XCTAssertFalse(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: false, isRunning: false, isInterrupted: false, isRecording: false))
    XCTAssertFalse(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: true, isRunning: true, isInterrupted: false, isRecording: false))
    XCTAssertFalse(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: true, isRunning: false, isInterrupted: true, isRecording: false))
    XCTAssertFalse(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: true, isRunning: false, isInterrupted: false, isRecording: true))
    XCTAssertFalse(
      CameraLifecycleLogic.shouldResumeSession(
        isWanted: true, isRunning: false, isInterrupted: false, isRecording: false,
        isDeviceConnected: false))
  }
}
