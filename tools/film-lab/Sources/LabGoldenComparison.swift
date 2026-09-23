import CoreImage
import Foundation

/// Re-renders the committed 1998 golden cases exactly as `GoldenRenderTests`
/// does (same seed search, context, software renderer and preview size) and
/// reports how far macOS output is from the simulator-generated references.
/// It never writes goldens.
enum LabGoldenComparison {
  static let fixtureNames = ["day-portrait", "night-flash", "hdr-still-life"]
  static let captureDate = Date(timeIntervalSince1970: 893_980_800)
  static let options = FilmProcessingOptions(
    lightLeaksEnabled: true,
    dateStamp: DateStampConfiguration(
      mode: .nostalgic1998, format: .yearMonthDay, localeIdentifier: "en_US_POSIX"))

  static func run(fixtures: URL, output: URL? = nil) -> Bool {
    let film = FilmRecipeCatalog.nineteenNinetyEight
    guard let filmIndex = FilmRecipeCatalog.all.firstIndex(where: { $0.id == film.id }) else {
      print("1998 recipe missing from the catalog")
      return false
    }
    let software = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    var ok = true
    print("1998 goldens: macOS renders vs the committed simulator references (≤1 LSB there).")
    print("  'software renderer' reproduces the golden harness: a software CIContext with Core")
    print("  Image's default (linear) working space. 'shared processor' is FilmProcessor.shared,")
    print("  the app's sRGB-working-space context the Lab and the app's still path use, so it is")
    print("  expected to differ from the goldens by more than platform noise.")
    for (fixtureIndex, name) in fixtureNames.enumerated() {
      var seed = UInt64(1_000 + filmIndex * 100 + fixtureIndex * 10)
      while !film.resolve(seed: seed, capturedAt: captureDate, options: options, timeZone: .gmt)
        .resolvedSettings.lightLeakApplied
      {
        seed += 1
      }
      let applied = film.resolve(
        seed: seed, capturedAt: captureDate, options: options, timeZone: .gmt)
      do {
        // The Lab's baseline for the same explicit context must be the same recipe.
        let context = try LabContext.validate(
          LabContextInput(
            seed: String(seed), capturedAt: LabContext.canonicalInstant(captureDate),
            timeZone: "GMT", photoQuality: "balanced"))
        let labRecipe = LabRecipeBuilder.build(controls: .empty, context: context)
        let recipeMatches = labRecipe == applied

        let source = try LabSelfTests.cgImage(fixtures.appendingPathComponent("\(name).png"))
        let reference = try LabBitmap(
          LabSelfTests.cgImage(fixtures.appendingPathComponent("golden-\(name)-aperture-1998.png")))
        let softwareRender = try render(software, source, applied)
        let sharedRender = try render(FilmProcessor.shared, source, labRecipe)
        if let output {
          try LabSelfTests.write(softwareRender, to: output.appendingPathComponent("\(name)-software.png"), type: "public.png")
          try LabSelfTests.write(sharedRender, to: output.appendingPathComponent("\(name)-shared.png"), type: "public.png")
        }
        let softwareDelta = try LabBitmap(softwareRender).difference(from: reference)
        let sharedDelta = try LabBitmap(sharedRender).difference(from: reference)
        func describe(_ delta: LabBitmap.Difference?) -> String {
          guard let delta else { return "size mismatch" }
          return "max \(delta.maximum), mean \(String(format: "%.4f", delta.mean)), >1 LSB \(delta.over1) values"
        }
        print("  \(name) seed \(seed): lab recipe == golden recipe: \(recipeMatches)")
        print("    software renderer: \(describe(softwareDelta))")
        print("    shared processor : \(describe(sharedDelta))")
        if !recipeMatches { ok = false }
        if softwareDelta == nil || sharedDelta == nil { ok = false }
      } catch {
        print("  \(name): \(error)")
        ok = false
      }
    }
    return ok
  }

  static func render(_ processor: FilmProcessor, _ source: CGImage, _ recipe: AppliedFilmRecipe)
    throws -> CGImage
  {
    let box = LabSelfTests.ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      do {
        box.set(
          .success(
            try await processor.renderedCGImage(
              CIImage(cgImage: source), recipe: recipe, orientation: .up,
              renderSize: .preview(maxPixelDimension: 256))))
      } catch {
        box.set(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try box.get()
  }
}
