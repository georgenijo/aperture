import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import Aperture

final class VideoProcessorTests: XCTestCase {
  func testTemporalSeedIsRepeatableAndVariesByFrameAndBaseSeed() {
    let baseSeed: UInt64 = 0x0123_4567_89AB_CDEF
    let firstPass = (0..<8).map {
      VideoProcessor.temporalSeed(baseSeed: baseSeed, frameIndex: $0)
    }
    let secondPass = (0..<8).map {
      VideoProcessor.temporalSeed(baseSeed: baseSeed, frameIndex: $0)
    }

    XCTAssertEqual(firstPass, secondPass)
    XCTAssertEqual(Set(firstPass).count, firstPass.count)
    XCTAssertNotEqual(
      VideoProcessor.temporalSeed(baseSeed: baseSeed, frameIndex: 0),
      VideoProcessor.temporalSeed(baseSeed: baseSeed &+ 1, frameIndex: 0)
    )
    XCTAssertEqual(
      VideoProcessor.temporalSeed(baseSeed: baseSeed, frameIndex: -1),
      VideoProcessor.temporalSeed(baseSeed: baseSeed, frameIndex: 0)
    )
  }

  func testGrainPhaseIsFiniteBoundedAndSeeded() {
    let phases = (0..<8).map {
      VideoProcessor.grainPhase(baseSeed: 42, frameIndex: $0)
    }

    XCTAssertTrue(phases.allSatisfy { $0.isFinite && (0...1).contains($0) })
    XCTAssertEqual(
      phases,
      (0..<8).map {
        VideoProcessor.grainPhase(baseSeed: 42, frameIndex: $0)
      })
    XCTAssertNotEqual(
      VideoProcessor.grainPhase(baseSeed: 42, frameIndex: 0),
      VideoProcessor.grainPhase(baseSeed: 43, frameIndex: 0)
    )
  }

  func testFrameTreatmentKeepsColorAndLeakStaticWhileGrainEvolves() {
    let recipe = makeRecipe(seed: 123)
    let first = VideoProcessor.frameTreatment(recipe: recipe, frameIndex: 0)
    let later = VideoProcessor.frameTreatment(recipe: recipe, frameIndex: 37)

    XCTAssertEqual(first.staticContrast, later.staticContrast)
    XCTAssertEqual(first.staticSaturation, later.staticSaturation)
    XCTAssertEqual(first.staticLeak, later.staticLeak)
    XCTAssertNotEqual(first.grainPhase, later.grainPhase)
  }

  func testDateStampedFrameTreatmentUsesPersistedTextAndStaticStyle() {
    let recipe = makeDateStampedRecipe(seed: 123)
    XCTAssertEqual(recipe.resolvedSettings.dateStampText, "1998 01 01")

    let first = VideoProcessor.frameTreatment(recipe: recipe, frameIndex: 0)
    let later = VideoProcessor.frameTreatment(recipe: recipe, frameIndex: 37)
    XCTAssertEqual(first.staticContrast, later.staticContrast)
    XCTAssertEqual(first.staticSaturation, later.staticSaturation)
    XCTAssertEqual(first.staticLeak, later.staticLeak)
    XCTAssertNotEqual(first.grainPhase, later.grainPhase)
  }

  func testLightLeakSelectedEdgeStartsAtEdgeAndFallsOffAtConfiguredWidth() {
    let extent = CGRect(x: 10, y: 20, width: 200, height: 100)
    let position = 0.35
    let width = 0.25
    let points = VideoProcessor.lightLeakGradientPoints(
      edge: .right, position: position, width: width, extent: extent)

    XCTAssertEqual(points.start.x, extent.maxX)
    XCTAssertEqual(points.start.y, extent.minY + CGFloat(position) * extent.height)
    XCTAssertEqual(points.end.x, extent.maxX - CGFloat(width) * extent.width)
    XCTAssertEqual(points.end.y, points.start.y)
    XCTAssertEqual(VideoProcessor.lightLeakOpacity(distance: 0, width: width), 1)
    XCTAssertEqual(
      VideoProcessor.lightLeakOpacity(distance: CGFloat(width) * 0.5, width: width), 0.5,
      accuracy: 0.0001)
    XCTAssertEqual(VideoProcessor.lightLeakOpacity(distance: width, width: width), 0)
    XCTAssertEqual(VideoProcessor.lightLeakOpacity(distance: width * 1.1, width: width), 0)

    let orientations: [(LightLeakDecision.Edge, CGPoint, CGPoint)] = [
      (.left, CGPoint(x: extent.minX, y: 55), CGPoint(x: 60, y: 55)),
      (.right, CGPoint(x: extent.maxX, y: 55), CGPoint(x: 160, y: 55)),
      (.top, CGPoint(x: 80, y: extent.maxY), CGPoint(x: 80, y: 95)),
      (.bottom, CGPoint(x: 80, y: extent.minY), CGPoint(x: 80, y: 45)),
    ]
    for (edge, expectedStart, expectedEnd) in orientations {
      let oriented = VideoProcessor.lightLeakGradientPoints(
        edge: edge, position: position, width: width, extent: extent)
      XCTAssertEqual(oriented.start.x, expectedStart.x, "Unexpected \(edge) start x")
      XCTAssertEqual(oriented.start.y, expectedStart.y, "Unexpected \(edge) start y")
      XCTAssertEqual(oriented.end.x, expectedEnd.x, "Unexpected \(edge) end x")
      XCTAssertEqual(oriented.end.y, expectedEnd.y, "Unexpected \(edge) end y")
    }
  }

  func testProcessRendersPlayableVideoWithDuration() async throws {
    let sourceURL = try makeTinyVideo()
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("aperture-video-output-\(UUID().uuidString).mov")
    defer {
      try? FileManager.default.removeItem(at: sourceURL)
      try? FileManager.default.removeItem(at: destinationURL)
    }

    let sourceAsset = AVURLAsset(url: sourceURL)
    let sourceHasAudio = !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty
    let outputURL = try await VideoProcessor().process(
      sourceURL: sourceURL, recipe: makeRecipe(seed: 7), destinationURL: destinationURL)
    let outputAsset = AVURLAsset(url: outputURL)

    let outputIsPlayable = try await outputAsset.load(.isPlayable)
    let outputVideoTracks = try await outputAsset.loadTracks(withMediaType: .video)
    let outputDuration = try await outputAsset.load(.duration)
    XCTAssertTrue(outputIsPlayable)
    XCTAssertFalse(outputVideoTracks.isEmpty)
    XCTAssertGreaterThan(outputDuration.seconds, 0)
    if sourceHasAudio {
      let outputAudioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
      XCTAssertFalse(outputAudioTracks.isEmpty)
    }
  }

  func testMissingSourceAndUnsupportedRecipeVersionFailBeforeExport() async throws {
    let missingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("aperture-test-missing-\(UUID().uuidString).mov")
    let valid = makeRecipe(seed: 7)

    let missingStamp = makeDateStampedRecipe(seed: valid.seed, includeText: false)
    do {
      _ = try await VideoProcessor.shared.process(sourceURL: missingURL, recipe: missingStamp)
      XCTFail("A date-stamped recipe without persisted text should fail before export")
    } catch let error as VideoProcessorError {
      XCTAssertEqual(error, .missingDateStampText)
    }

    do {
      _ = try await VideoProcessor.shared.process(sourceURL: missingURL, recipe: valid)
      XCTFail("A missing source should fail before export")
    } catch let error as VideoProcessorError {
      XCTAssertEqual(error, .sourceMissing)
    }

    let unsupported = AppliedFilmRecipe(
      identifier: valid.identifier,
      version: 2,
      seed: valid.seed,
      parameters: valid.parameters,
      resolvedSettings: valid.resolvedSettings
    )
    do {
      _ = try await VideoProcessor.shared.process(sourceURL: missingURL, recipe: unsupported)
      XCTFail("An unsupported recipe should fail before opening the source")
    } catch let error as VideoProcessorError {
      XCTAssertEqual(error, .unsupportedRecipeVersion(2))
    }
  }

  func testCancellationErrorRemainsDistinctAndDescriptive() {
    let error = VideoProcessorError.cancelled

    XCTAssertEqual(error, .cancelled)
    XCTAssertEqual(error.errorDescription, "Video development was cancelled.")
    XCTAssertNotEqual(error, .outputMissing)
  }

  private func makeRecipe(seed: UInt64) -> AppliedFilmRecipe {
    FilmRecipeCatalog.cinema.resolve(
      seed: seed,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      options: FilmProcessingOptions(lightLeaksEnabled: true, dateStamp: .off),
      timeZone: .gmt
    )
  }

  private func makeDateStampedRecipe(seed: UInt64, includeText: Bool = true) -> AppliedFilmRecipe {
    let valid = FilmRecipeCatalog.cinema.resolve(
      seed: seed,
      capturedAt: Date(timeIntervalSince1970: 915_148_800),
      options: FilmProcessingOptions(
        lightLeaksEnabled: true,
        dateStamp: DateStampConfiguration(
          mode: .nostalgic1998,
          format: .yearMonthDay,
          localeIdentifier: "en_US_POSIX"
        )
      ),
      timeZone: .gmt
    )
    guard includeText else {
      return AppliedFilmRecipe(
        identifier: valid.identifier,
        version: valid.version,
        seed: valid.seed,
        parameters: valid.parameters,
        resolvedSettings: FilmResolvedSettings(
          lightLeakApplied: valid.resolvedSettings.lightLeakApplied,
          dateStampConfiguration: valid.resolvedSettings.dateStampConfiguration,
          dateStampText: nil,
          timeZoneIdentifier: valid.resolvedSettings.timeZoneIdentifier,
          compressionQuality: valid.compressionQuality
        )
      )
    }
    return valid
  }

  private func makeTinyVideo() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("aperture-video-source-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let width = 64
    let height = 48
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 250_000,
          AVVideoExpectedSourceFrameRateKey: 10,
        ],
      ])
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw NSError(
        domain: "ApertureTests", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "The test video writer could not add its video input."
        ])
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.startWriting() else { throw writer.error ?? testVideoWriterError() }
    writer.startSession(atSourceTime: .zero)
    for frameIndex in 0..<3 {
      while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.001)
      }
      guard let pixelBuffer = makePixelBuffer(width: width, height: height, frameIndex: frameIndex),
        adaptor.append(
          pixelBuffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 10))
      else {
        input.markAsFinished()
        throw writer.error ?? testVideoWriterError()
      }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    guard semaphore.wait(timeout: .now() + 30) == .success else {
      throw testVideoWriterError()
    }
    guard writer.status == .completed else { throw writer.error ?? testVideoWriterError() }
    return url
  }

  private func makePixelBuffer(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes =
      [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
      ) == kCVReturnSuccess,
      let pixelBuffer
    else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
    let red = UInt8(80 + frameIndex * 20)
    let green = UInt8(110 + frameIndex * 10)
    let blue = UInt8(150)
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = blue
        pixels[offset + 1] = green
        pixels[offset + 2] = red
        pixels[offset + 3] = 255
      }
    }
    return pixelBuffer
  }

  private func testVideoWriterError() -> NSError {
    NSError(
      domain: "ApertureTests", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "The test video writer did not finish."])
  }
}
