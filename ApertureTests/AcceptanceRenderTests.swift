import CoreGraphics
import Foundation
import XCTest

@testable import Aperture

/// A manual acceptance harness for eyeballing full-resolution recipe output
/// against real photos, rather than synthetic fixtures. It is a no-op in the
/// ordinary automated suite: it skips unless `APERTURE_RENDER_SOURCE` is set.
///
/// Example (env vars need the `TEST_RUNNER_` prefix when passed to
/// `xcodebuild test`):
///   TEST_RUNNER_APERTURE_RENDER_SOURCE=/path/to/photo.jpg \
///   TEST_RUNNER_APERTURE_RENDER_OUTPUT=/tmp/rendered.jpg \
///   xcodebuild ... -only-testing:ApertureTests/AcceptanceRenderTests test
///
/// `APERTURE_RENDER_RECIPE` (default "1998") selects the catalog entry:
/// "1998", "night", "cinema", or "original". `APERTURE_RENDER_SEED" (default
/// 20_260_915) overrides the render seed.
final class AcceptanceRenderTests: XCTestCase {
  func testRendersConfiguredSourceThroughTheCatalog() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["APERTURE_RENDER_SOURCE"], !sourcePath.isEmpty else {
      throw XCTSkip(
        "Set APERTURE_RENDER_SOURCE (and APERTURE_RENDER_OUTPUT) to run this acceptance render.")
    }
    guard let outputPath = environment["APERTURE_RENDER_OUTPUT"], !outputPath.isEmpty else {
      throw XCTSkip("Set APERTURE_RENDER_OUTPUT to receive the rendered JPEG.")
    }

    let recipe = try catalogRecipe(for: environment["APERTURE_RENDER_RECIPE"])
    let seed = environment["APERTURE_RENDER_SEED"].flatMap { UInt64($0) } ?? 20_260_915

    let capturedAt = Date(timeIntervalSince1970: 1_789_500_000)
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let options = FilmProcessingOptions(
      lightLeaksEnabled: true,
      dateStamp: DateStampConfiguration(
        mode: .current, format: .huji, localeIdentifier: "en_US_POSIX"),
      photoQuality: .balanced
    )

    let applied = recipe.resolve(
      seed: seed, capturedAt: capturedAt, options: options, timeZone: timeZone)

    // `APERTURE_RENDER_SOURCE` may be a single image or a directory of them;
    // a directory renders every image into `APERTURE_RENDER_OUTPUT` (also a
    // directory) under the source file name with a `.jpg` extension.
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory)
    let jobs: [(source: URL, output: URL)]
    if isDirectory.boolValue {
      let sources = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: sourcePath), includingPropertiesForKeys: nil
      ).filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
      let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      jobs = sources.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
        ($0, outputDirectory.appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".jpg"))
      }
    } else {
      jobs = [(URL(fileURLWithPath: sourcePath), URL(fileURLWithPath: outputPath))]
    }

    for job in jobs {
      let sourceData = try Data(contentsOf: job.source)
      let rendered = try FilmProcessor.shared.process(sourceData, recipe: applied, renderSize: .full)
      try FilmProcessor.shared.encode(rendered, to: job.output, format: .jpeg, quality: 0.92)
      print(
        "[AcceptanceRenderTests] recipe=\(recipe.displayName) seed=\(seed) "
          + "lightLeakApplied=\(applied.resolvedSettings.lightLeakApplied) "
          + "dateStampText=\(applied.resolvedSettings.dateStampText ?? "<none>") "
          + "source=\(job.source.lastPathComponent) output=\(job.output.path)")
      XCTAssertTrue(FileManager.default.fileExists(atPath: job.output.path))
    }
  }

  private func catalogRecipe(for token: String?) throws -> FilmRecipe {
    switch token?.lowercased() {
    case nil, "1998", "nineteenninetyeight":
      return FilmRecipeCatalog.nineteenNinetyEight
    case "night":
      return FilmRecipeCatalog.night
    case "cinema":
      return FilmRecipeCatalog.cinema
    case "original", "legacyoriginal", "legacy-original":
      return FilmRecipeCatalog.legacyOriginal
    default:
      throw XCTSkip("Unknown APERTURE_RENDER_RECIPE \(token ?? "")")
    }
  }
}
