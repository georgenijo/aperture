import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// `film-lab-renderer selftest`: exercises the tool against the real shared
/// renderer. Exits non-zero on any failure.
struct LabSelfTests {
  let schema: ControlSchema
  let fixtures: URL
  private(set) var failures: [String] = []
  private(set) var checks = 0
  private var current = ""

  init(schema: ControlSchema, fixtures: URL) {
    self.schema = schema
    self.fixtures = fixtures
  }

  static let fixtureNames = ["day-portrait", "night-flash", "hdr-still-life"]
  static let bigSeeds: [UInt64] = [0, 1, 20_260_915, 9_007_199_254_740_993, UInt64.max]

  var defaultContext: LabContext { try! LabContext.validate(schema.defaultContext) }

  func context(seed: UInt64, zone: String = "America/New_York", quality: String = "balanced")
    -> LabContext
  {
    try! LabContext.validate(
      LabContextInput(
        seed: String(seed), capturedAt: "2026-09-15T19:20:00Z", timeZone: zone,
        photoQuality: quality))
  }

  func fixture(_ name: String) -> URL { fixtures.appendingPathComponent("\(name).png") }

  /// The first seed at or above `start` whose baseline leak decision matches.
  func seed(leak: Bool, from start: UInt64 = 1_000) -> UInt64 {
    var seed = start
    while LabRecipeBuilder.baseline(for: context(seed: seed)).resolved.resolvedSettings
      .lightLeakApplied != leak
    {
      seed += 1
    }
    return seed
  }

  mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition { failures.append("[\(current)] \(message())") }
  }

  mutating func run() -> Bool {
    let tests: [(String, (inout LabSelfTests) throws -> Void)] = [
      ("handler coverage", { try $0.handlerCoverage() }),
      ("schema neutrals match shipping recipe", { try $0.schemaMatchesRecipe() }),
      ("default equals direct shipping resolution", { try $0.defaultEqualsDirect() }),
      ("exact reset", { try $0.exactReset() }),
      ("control limits", { try $0.controlLimits() }),
      ("every control changes recipe and pixels", { try $0.everyControlHasEffect() }),
      ("effect toggles switch stages fully off", { try $0.togglesSwitchOff() }),
      ("monotone bounded tone transforms", { try $0.monotoneTone() }),
      ("light-leak overrides", { try $0.leakOverrides() }),
      ("date-stamp override", { try $0.stampOverride() }),
      ("context validation", { try $0.contextValidation() }),
      ("deterministic renders", { try $0.determinism() }),
      ("candidate round trip incl. seeds above 2^53", { try $0.candidateRoundTrip() }),
      ("candidate rejections", { try $0.candidateRejections() }),
      ("worker path confinement", { try $0.workerPaths() }),
      ("image input validation", { try $0.imageInputs() }),
      ("orientation and Display P3 originals", { try $0.orientationAndColour() }),
      ("same-size fidelity vs direct renderer", { try $0.sameSizeFidelity() }),
    ]
    for (name, test) in tests {
      current = name
      let before = failures.count
      let started = Date()
      do {
        try test(&self)
      } catch {
        failures.append("[\(name)] threw \(error)")
      }
      let status = failures.count == before ? "ok  " : "FAIL"
      print("\(status) \(name) (\(LabWorker.milliseconds(since: started)) ms)")
    }
    print("\(checks) checks, \(failures.count) failures")
    for failure in failures { print("  - \(failure)") }
    return failures.isEmpty
  }

  // MARK: - Schema

  mutating func handlerCoverage() throws {
    let handlerIDs = LabRecipeBuilder.handlers.map(\.id)
    let declared = schema.controls.map(\.id)
    check(Set(handlerIDs).count == handlerIDs.count, "duplicate handler ids \(handlerIDs)")
    check(Set(declared).count == declared.count, "duplicate declared ids")
    for id in declared {
      check(handlerIDs.filter { $0 == id }.count == 1, "control \(id) must have exactly one handler")
    }
    for id in handlerIDs {
      check(declared.contains(id), "handler \(id) has no declared control")
    }
    let leakMode = handlerIDs.firstIndex(of: "lightLeak") ?? -1
    let leakStrength = handlerIDs.firstIndex(of: "lightLeakStrength") ?? -1
    check(leakMode >= 0 && leakMode < leakStrength, "lightLeak must run before lightLeakStrength")
  }

  mutating func schemaMatchesRecipe() throws {
    let recipe = LabRecipeBuilder.baseRecipe
    check(schema.baseRecipeID == recipe.id.rawValue, "base recipe id")
    check(schema.baseRecipeVersion == recipe.version, "base recipe version")
    let stages = recipe.stages
    let expected: [String: Double?] = [
      "halation": stages.halation?.amount,
      "softness": stages.softness?.amount,
      "fringing": stages.chromaticAberration?.amount,
      "grainAmount": stages.grain?.amount,
      "grainSize": stages.grain?.size,
      "vignette": stages.vignette?.amount,
      "lightLeakStrength": stages.lightLeak?.strength,
    ]
    for (id, value) in expected {
      guard case .number(_, _, let neutral)? = schema.definition(for: id)?.kind else {
        check(false, "\(id) missing or not numeric")
        continue
      }
      check(value == neutral, "\(id) neutral \(neutral) must equal shipping value \(String(describing: value))")
    }
    check(schema.photoQualityOptions == PhotoQualityPreference.allCases.map(\.rawValue), "photo quality options")
  }

  // MARK: - Recipe building

  mutating func defaultEqualsDirect() throws {
    for seed in Self.bigSeeds + [seed(leak: true), seed(leak: false)] {
      for quality in PhotoQualityPreference.allCases {
        let context = context(seed: seed, quality: quality.rawValue)
        let direct = FilmRecipeCatalog.nineteenNinetyEight.resolve(
          seed: seed, capturedAt: context.capturedAt,
          options: FilmProcessingOptions(
            lightLeaksEnabled: true, dateStamp: .off, photoQuality: quality),
          timeZone: context.timeZone)
        let built = LabRecipeBuilder.build(controls: .empty, context: context)
        check(built == direct, "seed \(seed) \(quality) default differs from direct resolution")
        check(
          try LabFingerprint.of(built) == LabFingerprint.of(direct),
          "seed \(seed) fingerprint differs")
        check(built.seed == seed, "seed \(seed) not preserved")
      }
    }
    // The 1998 recipe forces its stamp, regardless of the app's option.
    let stamped = LabRecipeBuilder.build(controls: .empty, context: defaultContext)
    check(stamped.resolvedSettings.dateStampText == "9 15 '26", "stamp text \(stamped.resolvedSettings.dateStampText ?? "nil")")
  }

  mutating func exactReset() throws {
    let base = LabRecipeBuilder.build(controls: .empty, context: defaultContext)
    var everything: [String: LabControlValue] = [:]
    var neutrals: [String: LabControlValue] = [:]
    for definition in schema.controls {
      neutrals[definition.id] = definition.neutralValue
      switch definition.kind {
      case .number(_, let max, let neutral):
        everything[definition.id] = .number(max == neutral ? neutral - 0.1 : max)
      case .choice(let options, let neutral):
        everything[definition.id] = .choice(options.first { $0 != neutral } ?? neutral)
      }
    }
    let changed = LabRecipeBuilder.build(controls: try schema.validate(everything), context: defaultContext)
    check(changed != base, "setting every control must change the recipe")
    let reset = try schema.validate(neutrals)
    check(reset.values.isEmpty, "neutral values must canonicalise away")
    check(LabRecipeBuilder.build(controls: reset, context: defaultContext) == base, "reset is not exact")
    check(LabRecipeBuilder.build(controls: .empty, context: defaultContext) == base, "unset is not exact")
  }

  mutating func controlLimits() throws {
    for definition in schema.controls {
      switch definition.kind {
      case .number(let min, let max, _):
        for value in [min, max] {
          check((try? schema.validate([definition.id: .number(value)])) != nil, "\(definition.id) rejects limit \(value)")
        }
        for value in [min - 0.001, max + 0.001, .nan, .infinity, -.infinity] {
          check((try? schema.validate([definition.id: .number(value)])) == nil, "\(definition.id) accepts \(value)")
        }
        check((try? schema.validate([definition.id: .choice("on")])) == nil, "\(definition.id) accepts a string")
      case .choice(let options, _):
        for option in options {
          check((try? schema.validate([definition.id: .choice(option)])) != nil, "\(definition.id) rejects \(option)")
        }
        check((try? schema.validate([definition.id: .choice("maybe")])) == nil, "\(definition.id) accepts junk")
        check((try? schema.validate([definition.id: .number(1)])) == nil, "\(definition.id) accepts a number")
      }
    }
    check((try? schema.validate(["exposure": .number(0)])) == nil, "unknown control accepted")
  }

  /// A setting that is visibly non-neutral for each control, plus a seed
  /// where that control can act (leak strength needs a leak).
  func probe(for definition: ControlDefinition) -> (LabControlValue, UInt64) {
    switch definition.id {
    case "lightLeakStrength": return (.number(0.9), seed(leak: true))
    case "lightLeak": return (.choice("on"), seed(leak: false))
    case "dateStamp": return (.choice("off"), 20_260_915)
    case "softness": return (.number(1), 20_260_915)
    default: break
    }
    switch definition.kind {
    case .number(let min, let max, let neutral):
      return (.number(max - neutral >= neutral - min ? max : min), 20_260_915)
    case .choice(let options, let neutral):
      return (.choice(options.first { $0 != neutral } ?? neutral), 20_260_915)
    }
  }

  mutating func everyControlHasEffect() throws {
    let source = fixture("day-portrait")
    for definition in schema.controls {
      let (value, seed) = probe(for: definition)
      let context = context(seed: seed)
      let base = LabRecipeBuilder.build(controls: .empty, context: context)
      let applied = LabRecipeBuilder.build(
        controls: try schema.validate([definition.id: value]), context: context)
      check(applied != base, "\(definition.id) did not change the recipe")
      check(applied.stages.count == base.stages.count, "\(definition.id) changed the stage count")
      check(
        zip(applied.stages, base.stages).allSatisfy { Self.kind($0) == Self.kind($1) },
        "\(definition.id) changed the stage order")
      check(applied.seed == base.seed, "\(definition.id) changed the seed")
      // Full resolution: softness and grain are resolution dependent and
      // nearly vanish in small previews.
      let before = try LabImaging.renderRGBA(source: source, recipe: base, renderSize: .full)
      let after = try LabImaging.renderRGBA(source: source, recipe: applied, renderSize: .full)
      let difference = after.difference(from: before)
      check((difference?.maximum ?? 0) > 2, "\(definition.id) had no visible pixel effect (max delta \(difference?.maximum ?? -1))")
    }
  }

  mutating func togglesSwitchOff() throws {
    for seed in Self.bigSeeds {
      let context = context(seed: seed)
      let off = try schema.validate([
        "halation": .number(0), "softness": .number(0), "fringing": .number(0),
        "grainAmount": .number(0), "vignette": .number(0),
      ])
      let applied = LabRecipeBuilder.build(controls: off, context: context)
      check(applied.halation?.amount == 0, "halation off (seed \(seed))")
      check(applied.softness?.amount == 0, "softness off (seed \(seed))")
      check(applied.chromaticAberration?.amount == 0, "fringing off (seed \(seed))")
      check(applied.grain?.amount == 0, "grain off must not keep seeded jitter (seed \(seed))")
      check(applied.vignette?.amount == 0, "vignette off (seed \(seed))")
      // A small positive amount still keeps the seed's jitter, as the app does.
      let low = LabRecipeBuilder.build(controls: try schema.validate(["grainAmount": .number(0.05)]), context: context)
      let base = LabRecipeBuilder.build(controls: .empty, context: context)
      let jitter = (base.grain?.amount ?? 0) - (LabRecipeBuilder.baseRecipe.stages.grain?.amount ?? 0)
      check(low.grain?.amount == min(max(0.05 + jitter, 0), 1), "grain jitter kept above zero (seed \(seed))")
    }
  }

  static func kind(_ stage: FilmStage) -> String {
    String(String(describing: stage).prefix { $0 != "(" })
  }

  mutating func monotoneTone() throws {
    let toneIDs = schema.controls.filter { $0.group == "tone" }.map(\.id)
    // Every tone control at each limit, alone and all together, keeps every
    // curve monotone and inside [0, 1] and every parameter finite.
    var combos: [[String: LabControlValue]] = [[:]]
    for id in toneIDs {
      guard case .number(let min, let max, _)? = schema.definition(for: id)?.kind else { continue }
      combos.append([id: .number(min)])
      combos.append([id: .number(max)])
    }
    combos.append(Dictionary(uniqueKeysWithValues: toneIDs.map { ($0, LabControlValue.number(1)) }))
    combos.append(Dictionary(uniqueKeysWithValues: toneIDs.map { id -> (String, LabControlValue) in
      guard case .number(let min, _, _)? = schema.definition(for: id)?.kind else { return (id, .number(0)) }
      return (id, .number(min))
    }))
    for combo in combos {
      let applied = LabRecipeBuilder.build(controls: try schema.validate(combo), context: defaultContext)
      guard let response = applied.filmResponse else {
        check(false, "film response missing")
        continue
      }
      for curve in response.curves {
        check(curve.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "\(combo) curve out of [0,1]")
        check(zip(curve, curve.dropFirst()).allSatisfy { $0 <= $1 }, "\(combo) curve not monotone")
      }
      let all = response.matrix + response.saturation + response.hueChroma + response.hueRotate + response.hueLight
      check(all.allSatisfy(\.isFinite), "\(combo) non-finite response parameter")
      check(response.saturation.allSatisfy { $0 >= 0 }, "\(combo) negative chroma gain")
      // Tone order survives: black ≤ grey ≤ white, all inside the unit cube.
      let ramp = [0.0, 0.25, 0.5, 0.75, 1.0].map {
        FilmResponseModel.map(FilmRGB(red: $0, green: $0, blue: $0), response: response)
      }
      check(ramp.allSatisfy { [$0.red, $0.green, $0.blue].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }, "\(combo) grey ramp left the unit cube")
      check(zip(ramp, ramp.dropFirst()).allSatisfy { $0.luminance < $1.luminance }, "\(combo) grey ramp not increasing")
    }

    // Effects are monotone in the control value.
    func mapped(_ id: String, _ value: Double, _ colour: FilmRGB) throws -> FilmRGB {
      let applied = LabRecipeBuilder.build(
        controls: try schema.validate([id: .number(value)]), context: defaultContext)
      return FilmResponseModel.map(colour, response: applied.filmResponse!)
    }
    let sweep = stride(from: -1.0, through: 1.0, by: 0.25).map { $0 }
    let mid = FilmRGB(red: 0.45, green: 0.45, blue: 0.45)
    let shadow = FilmRGB(red: 0.2, green: 0.2, blue: 0.2)
    let highlight = FilmRGB(red: 0.8, green: 0.8, blue: 0.8)
    let saturated = FilmRGB(red: 0.7, green: 0.35, blue: 0.25)
    func chroma(_ c: FilmRGB) -> Double {
      let lab = FilmResponseModel.oklab(fromLinear: (
        FilmResponseModel.srgbToLinear(c.red), FilmResponseModel.srgbToLinear(c.green),
        FilmResponseModel.srgbToLinear(c.blue)))
      return (lab.1 * lab.1 + lab.2 * lab.2).squareRoot()
    }
    let brightness = try sweep.map { try mapped("brightness", $0, mid).luminance }
    check(zip(brightness, brightness.dropFirst()).allSatisfy { $0 < $1 }, "brightness not increasing \(brightness)")
    let shadows = try sweep.map { try mapped("contrast", $0, shadow).luminance }
    let highlights = try sweep.map { try mapped("contrast", $0, highlight).luminance }
    check(zip(shadows, shadows.dropFirst()).allSatisfy { $0 > $1 }, "contrast not darkening shadows \(shadows)")
    check(zip(highlights, highlights.dropFirst()).allSatisfy { $0 < $1 }, "contrast not lifting highlights \(highlights)")
    let warmth = try sweep.map { value -> Double in
      let c = try mapped("warmth", value, mid)
      return c.red - c.blue
    }
    check(zip(warmth, warmth.dropFirst()).allSatisfy { $0 < $1 }, "warmth not increasing \(warmth)")
    let chromas = try sweep.map { try chroma(mapped("chroma", $0, saturated)) }
    // Non-decreasing: the most saturated settings can reach the gamut edge.
    check(zip(chromas, chromas.dropFirst()).allSatisfy { $0 <= $1 } && chromas.last! > chromas.first!, "chroma not increasing \(chromas)")
    // Measure the chroma controls inside the gamut. At a clipped highlight,
    // increasing the requested chroma can lower the final RGB chroma as one
    // channel hits white; that is gamut clipping, not a reversed control.
    for (id, colour) in [("shadowChroma", FilmRGB(red: 0.3, green: 0.25, blue: 0.2)), ("highlightChroma", FilmRGB(red: 0.8, green: 0.75, blue: 0.7))] {
      let mappedColours = try sweep.map { try mapped(id, $0, colour) }
      check(mappedColours.allSatisfy {
        [$0.red, $0.green, $0.blue].allSatisfy { $0 > 0 && $0 < 1 }
      }, "\(id) monotonicity probe must stay inside the gamut")
      let values = mappedColours.map(chroma)
      check(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } && values.last! > values.first!, "\(id) not increasing \(values)")
    }
    for (id, colour) in [("shadowChroma", FilmRGB(red: 0.3, green: 0.12, blue: 0.08)), ("highlightChroma", FilmRGB(red: 0.95, green: 0.75, blue: 0.6))] {
      for value in sweep {
        let mappedColour = try mapped(id, value, colour)
        check([mappedColour.red, mappedColour.green, mappedColour.blue].allSatisfy {
          $0.isFinite && $0 >= 0 && $0 <= 1
        }, "clipped \(id) must remain finite and bounded at \(value)")
      }
    }
  }

  mutating func leakOverrides() throws {
    let recipeLeak = LabRecipeBuilder.baseRecipe.stages.lightLeak!

    let offSeed = seed(leak: false)
    let forced = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeak": .choice("on")]), context: context(seed: offSeed))
    check(forced.resolvedSettings.lightLeakApplied, "forcing on must set lightLeakApplied")
    check(forced.lightLeak?.probability == recipeLeak.probability, "forced probability")
    check(forced.lightLeak?.strength == recipeLeak.strength, "forced strength must be positive recipe strength")
    check(FilmProcessingDecision.make(for: forced).leak != nil, "forced leak must produce a decision")
    let offBase = LabRecipeBuilder.build(controls: .empty, context: context(seed: offSeed))
    check(FilmProcessingDecision.make(for: offBase).leak == nil, "baseline no-leak seed produced a leak")

    let onSeed = seed(leak: true)
    let onBase = LabRecipeBuilder.build(controls: .empty, context: context(seed: onSeed))
    let disabled = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeak": .choice("off")]), context: context(seed: onSeed))
    check(!disabled.resolvedSettings.lightLeakApplied, "off must clear lightLeakApplied")
    check(disabled.lightLeak?.probability == 0 && disabled.lightLeak?.strength == 0, "off must zero the stage")
    check(FilmProcessingDecision.make(for: disabled).leak == nil, "off still produced a leak")
    check(
      LabRecipeBuilder.build(controls: try schema.validate(["lightLeak": .choice("on")]), context: context(seed: onSeed)) == onBase,
      "on with a seeded leak must be identity")

    // Strength keeps the seed's own strength scale, and zero disables.
    let scale = onBase.lightLeak!.strength / recipeLeak.strength
    let stronger = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeakStrength": .number(0.6)]), context: context(seed: onSeed))
    check(abs(stronger.lightLeak!.strength - min(1, 0.6 * scale)) < 1e-12, "strength scaling")
    check(stronger.resolvedSettings.lightLeakApplied, "strength must keep leak applied")
    let zero = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeakStrength": .number(0)]), context: context(seed: onSeed))
    check(!zero.resolvedSettings.lightLeakApplied && zero.lightLeak?.strength == 0, "zero strength must disable the leak")
    let forcedStrong = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeak": .choice("on"), "lightLeakStrength": .number(0.8)]),
      context: context(seed: offSeed))
    check(forcedStrong.lightLeak?.strength == 0.8, "forced leak takes the strength unscaled")
    let noLeakStrength = LabRecipeBuilder.build(
      controls: try schema.validate(["lightLeakStrength": .number(0.8)]), context: context(seed: offSeed))
    check(noLeakStrength == offBase, "strength without a leak must not create one")

    // Real-engine behaviour: leak occurrence changes later RNG draws.
    let grainOn = FilmProcessingDecision.make(for: onBase).grainSeed
    let grainOff = FilmProcessingDecision.make(for: disabled).grainSeed
    print("     note: seed \(onSeed) grain seed with leak \(grainOn), without \(grainOff) (\(grainOn == grainOff ? "same" : "differs"), as FilmProcessingDecision draws conditionally)")
  }

  mutating func stampOverride() throws {
    let base = LabRecipeBuilder.build(controls: .empty, context: defaultContext)
    let hidden = LabRecipeBuilder.build(
      controls: try schema.validate(["dateStamp": .choice("off")]), context: defaultContext)
    check(hidden.resolvedSettings.dateStampText == nil, "hidden stamp must drop the text")
    check(hidden.resolvedSettings.dateStampConfiguration.mode == .off, "hidden stamp mode")
    check(hidden.stages == base.stages, "hiding the stamp must not touch stages")
    check(hidden.resolvedSettings.lightLeakApplied == base.resolvedSettings.lightLeakApplied, "stamp changed leak")
    // The stamp follows the explicit context, never the clock.
    let tokyo = LabRecipeBuilder.build(controls: .empty, context: context(seed: 1, zone: "Asia/Tokyo"))
    check(tokyo.resolvedSettings.dateStampText == "9 16 '26", "time zone must drive the stamp: \(tokyo.resolvedSettings.dateStampText ?? "nil")")
    check(tokyo.resolvedSettings.timeZoneIdentifier == "Asia/Tokyo", "time zone identifier")
  }

  mutating func contextValidation() throws {
    let good = schema.defaultContext
    func variant(seed: String? = nil, at: String? = nil, zone: String? = nil, quality: String? = nil) -> LabContextInput {
      LabContextInput(seed: seed ?? good.seed, capturedAt: at ?? good.capturedAt, timeZone: zone ?? good.timeZone, photoQuality: quality ?? good.photoQuality)
    }
    for seed in ["", "-1", "01", "1e3", "18446744073709551616", "１２", " 1", "0x10", "1.0"] {
      check((try? LabContext.validate(variant(seed: seed))) == nil, "seed \(seed) accepted")
    }
    check((try? LabContext.validate(variant(seed: "18446744073709551615")))?.seed == UInt64.max, "max seed")
    check((try? LabContext.validate(variant(seed: "0")))?.seed == 0, "zero seed")
    for at in ["2026-09-15T19:20:00", "2026-09-15", "yesterday", "2026-09-15T19:20:00.5Z", "2200-01-01T00:00:00Z"] {
      check((try? LabContext.validate(variant(at: at))) == nil, "instant \(at) accepted")
    }
    let offset = try LabContext.validate(variant(at: "2026-09-15T15:20:00-04:00"))
    check(offset.input.capturedAt == "2026-09-15T19:20:00Z", "offset instant must canonicalise to UTC")
    for zone in ["Mars/Olympus", "../../etc", "", "EST5EDT\n"] {
      check((try? LabContext.validate(variant(zone: zone))) == nil, "zone \(zone) accepted")
    }
    check((try? LabContext.validate(variant(quality: "ultra"))) == nil, "quality accepted")
    check(try LabContext.validate(variant(quality: "maximum")).photoQuality == .maximum, "quality maximum")
  }

  mutating func determinism() throws {
    let source = fixture("night-flash")
    let controls = try schema.validate(["brightness": .number(0.3), "grainAmount": .number(0.5), "lightLeak": .choice("on")])
    let first = LabRecipeBuilder.build(controls: controls, context: defaultContext)
    let second = LabRecipeBuilder.build(controls: controls, context: defaultContext)
    check(first == second, "same settings built different recipes")
    let a = try LabImaging.renderJPEG(source: source, recipe: first, renderSize: .preview(maxPixelDimension: 640), quality: 0.9)
    let b = try LabImaging.renderJPEG(source: source, recipe: second, renderSize: .preview(maxPixelDimension: 640), quality: 0.9)
    check(a.data == b.data, "same settings rendered different JPEG bytes")
    let otherSeed = LabRecipeBuilder.build(controls: controls, context: context(seed: 7))
    let c = try LabImaging.renderJPEG(source: source, recipe: otherSeed, renderSize: .preview(maxPixelDimension: 640), quality: 0.9)
    check(a.data != c.data, "a different seed must change the render")
  }

  // MARK: - Candidates

  var provenance: LabCandidate.Provenance {
    LabCandidate.Provenance(
      tool: "aperture-film-lab", toolVersion: "selftest", createdAt: "2026-09-22T00:00:00Z",
      gitCommit: nil, renderer: "selftest")
  }

  mutating func candidateRoundTrip() throws {
    for seed in Self.bigSeeds {
      let context = context(seed: seed, zone: "Europe/London", quality: "maximum")
      let controls = try schema.validate([
        "contrast": .number(0.37), "warmth": .number(-0.21), "halation": .number(0.55),
        "lightLeak": .choice("on"), "dateStamp": .choice("off"),
      ])
      let made = try LabCandidate.make(name: "  Round trip \(seed)  ", controls: controls, context: context, schema: schema, provenance: provenance)
      check(made.candidate.name == "Round trip \(seed)", "name trimming")
      check(made.text.contains("\"seed\" : \"\(seed)\""), "context seed must be a decimal string")
      check(made.text.contains("\"seed\" : \(seed),"), "applied seed must be the exact integer \(seed)")
      let imported = try LabCandidate.importText(made.text, schema: schema)
      check(imported.controls == controls, "controls round trip")
      check(imported.context == context, "context round trip")
      check(imported.applied == LabRecipeBuilder.build(controls: controls, context: context), "applied round trip")
      check(imported.applied.seed == seed, "seed \(seed) round trip")
      check(imported.verifiedSnapshot, "snapshot must be verified")
      let again = try LabCandidate.make(name: imported.name, controls: imported.controls, context: imported.context, schema: schema, provenance: provenance)
      check(again.text == made.text, "export → import → export must be byte-identical")
    }
  }

  mutating func candidateRejections() throws {
    let controls = try schema.validate(["brightness": .number(0.25), "lightLeak": .choice("off")])
    let text = try LabCandidate.make(name: "Base", controls: controls, context: defaultContext, schema: schema, provenance: provenance).text
    func object(_ text: String) -> [String: Any] {
      try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    func serialize(_ object: [String: Any]) -> String {
      String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func expectRejected(_ candidateText: String, _ code: String, _ label: String) {
      do {
        _ = try LabCandidate.importText(candidateText, schema: schema)
        check(false, "\(label) was accepted")
      } catch let error as LabError {
        check(error.code == code, "\(label): expected \(code), got \(error.code)")
      } catch {
        check(false, "\(label): unexpected \(error)")
      }
    }

    // Tampered snapshot: one stage number changed.
    var tampered = object(text)
    var applied = tampered["appliedRecipe"] as! [String: Any]
    var stages = applied["stages"] as! [[String: Any]]
    var vignette = stages[stages.count - 1]
    var configuration = vignette["configuration"] as! [String: Any]
    configuration["amount"] = 0.9
    vignette["configuration"] = configuration
    stages[stages.count - 1] = vignette
    applied["stages"] = stages
    tampered["appliedRecipe"] = applied
    expectRejected(serialize(tampered), "snapshot-mismatch", "tampered stage value")

    // Arbitrary stage injection.
    var injected = object(text)
    var injectedApplied = injected["appliedRecipe"] as! [String: Any]
    var injectedStages = injectedApplied["stages"] as! [[String: Any]]
    injectedStages.insert(["kind": "colorGrade", "configuration": ["exposure": 1, "contrast": 1.5, "saturation": 1.6, "warmth": 1, "highlightRolloff": 0, "shadowCoolness": 0]], at: 0)
    injectedApplied["stages"] = injectedStages
    injected["appliedRecipe"] = injectedApplied
    expectRejected(serialize(injected), "snapshot-mismatch", "injected colour-grade stage")

    // Malformed snapshot fields the app's lenient decoders would normalise.
    func withResponse(_ edit: (inout [String: Any]) -> Void) -> String {
      var candidate = object(text)
      var applied = candidate["appliedRecipe"] as! [String: Any]
      var stages = applied["stages"] as! [[String: Any]]
      let index = stages.firstIndex { ($0["kind"] as? String) == "filmResponse" }!
      var configuration = stages[index]["configuration"] as! [String: Any]
      edit(&configuration)
      stages[index]["configuration"] = configuration
      applied["stages"] = stages
      candidate["appliedRecipe"] = applied
      return serialize(candidate)
    }
    expectRejected(withResponse { $0["matrix"] = [123] }, "snapshot-mismatch", "short crosstalk matrix")
    expectRejected(withResponse { $0.removeValue(forKey: "matrix") }, "snapshot-mismatch", "missing crosstalk matrix")
    expectRejected(withResponse { $0["note"] = "extra" }, "snapshot-mismatch", "extra snapshot field")
    func shape(_ json: String) -> LabJSONShape { try! JSONDecoder().decode(LabJSONShape.self, from: Data(json.utf8)) }
    check(shape(text) == shape(text), "structural equality is reflexive")
    check(shape("[true]") != shape("[1]"), "a boolean never equals a number")
    check(shape("[0.0026, 2]") == shape("[0.0025999999999999999, 2.0]"), "numbers compare as doubles")
    check(shape("{\"a\":1}") != shape("{\"a\":1,\"b\":null}"), "extra keys differ")

    var wrongFingerprint = object(text)
    wrongFingerprint["appliedRecipeFingerprint"] = "sha256:" + String(repeating: "0", count: 64)
    expectRejected(serialize(wrongFingerprint), "snapshot-mismatch", "wrong fingerprint")

    var fingerprintOnly = object(text)
    fingerprintOnly.removeValue(forKey: "appliedRecipe")
    expectRejected(serialize(fingerprintOnly), "snapshot-incomplete", "fingerprint without snapshot")

    var extra = object(text)
    extra["install"] = true
    expectRejected(serialize(extra), "unknown-field", "unknown top-level field")

    var schemaVersion = object(text)
    schemaVersion["schemaVersion"] = 2
    expectRejected(serialize(schemaVersion), "unsupported-schema", "future schema version")

    var otherSchema = object(text)
    otherSchema["schema"] = "aperture.media-library"
    expectRejected(serialize(otherSchema), "unsupported-schema", "wrong schema name")

    var baseline = object(text)
    baseline["base"] = ["recipeId": "aperture.1998", "recipeVersion": 4, "fingerprint": "sha256:" + String(repeating: "1", count: 64)]
    expectRejected(serialize(baseline), "unsupported-baseline", "different base fingerprint")

    var night = object(text)
    night["base"] = ["recipeId": "aperture.night", "recipeVersion": 4, "fingerprint": (object(text)["base"] as! [String: Any])["fingerprint"]!]
    expectRejected(serialize(night), "unsupported-baseline", "different base recipe")

    var previousVersion = object(text)
    var previousBase = previousVersion["base"] as! [String: Any]
    previousBase["recipeVersion"] = LabRecipeBuilder.baseRecipe.version - 1
    previousVersion["base"] = previousBase
    expectRejected(serialize(previousVersion), "unsupported-baseline", "previous recipe version")

    var outOfRange = object(text)
    outOfRange["controls"] = ["brightness": 3]
    outOfRange.removeValue(forKey: "appliedRecipe")
    outOfRange.removeValue(forKey: "appliedRecipeFingerprint")
    expectRejected(serialize(outOfRange), "control-out-of-range", "out-of-range control")

    var unknownControl = object(text)
    unknownControl["controls"] = ["exposure": 0.5]
    expectRejected(serialize(unknownControl), "unknown-control", "unknown control")

    var nested = object(text)
    nested["controls"] = ["brightness": ["value": 0.5]]
    expectRejected(serialize(nested), "invalid-candidate", "nested control value")

    var badSeed = object(text)
    var badContext = badSeed["context"] as! [String: Any]
    badContext["seed"] = 12
    badSeed["context"] = badContext
    expectRejected(serialize(badSeed), "invalid-candidate", "numeric seed")
    badContext["seed"] = "99999999999999999999"
    badSeed["context"] = badContext
    expectRejected(serialize(badSeed), "invalid-seed", "overflowing seed")

    var badName = object(text)
    badName["name"] = "bad\u{0007}name"
    expectRejected(serialize(badName), "invalid-name", "control character in name")
    badName["name"] = String(repeating: "x", count: 81)
    expectRejected(serialize(badName), "invalid-name", "overlong name")

    var changedSchema = object(text)
    changedSchema["controlSchema"] = ["version": schema.version, "digest": "sha256:" + String(repeating: "2", count: 64)]
    check((try? LabCandidate.importText(serialize(changedSchema), schema: schema)) != nil, "changed digest with a verified snapshot must import")
    changedSchema.removeValue(forKey: "appliedRecipe")
    changedSchema.removeValue(forKey: "appliedRecipeFingerprint")
    expectRejected(serialize(changedSchema), "control-schema-changed", "changed digest without snapshot")

    // Controls and context alone (no snapshot) are a valid hand-written candidate.
    var minimal = object(text)
    minimal.removeValue(forKey: "appliedRecipe")
    minimal.removeValue(forKey: "appliedRecipeFingerprint")
    minimal.removeValue(forKey: "provenance")
    check((try? LabCandidate.importText(serialize(minimal), schema: schema))?.verifiedSnapshot == false, "minimal candidate")

    expectRejected("[1,2,3]", "invalid-json", "array document")
    expectRejected("{", "invalid-json", "truncated document")
  }

  // MARK: - Worker and images

  mutating func workerPaths() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = LabWorker(schema: schema, root: root, testHooks: false, maximumPixels: LabImaging.defaultMaximumPixels)
    let inside = root.appendingPathComponent("a.png")
    try FileManager.default.copyItem(at: fixture("day-portrait"), to: inside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"), withDestinationURL: fixture("day-portrait"))
    func response(_ object: [String: Any]) -> [String: Any] {
      let line = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      return try! JSONSerialization.jsonObject(with: worker.handle(line: line)) as! [String: Any]
    }
    func errorCode(_ object: [String: Any]) -> String? {
      (response(object)["error"] as? [String: Any])?["code"] as? String
    }
    check(response(["id": 1, "op": "inspect", "source": inside.path])["ok"] as? Bool == true, "inside path must work")
    for path in ["/etc/hosts", root.path + "/../x.png", "relative.png", root.appendingPathComponent("escape.png").path, fixture("day-portrait").path] {
      check(errorCode(["id": 2, "op": "inspect", "source": path]) == "bad-path", "source \(path) not confined")
    }
    let context: [String: Any] = ["seed": "1", "capturedAt": "2026-09-15T19:20:00Z", "timeZone": "UTC", "photoQuality": "balanced"]
    for output in ["/tmp/film-lab-escape.jpg", root.path + "/../escape.jpg", root.path + "/sub/../../escape.jpg", root.path + "/.hidden.jpg", root.path + "/a b.jpg"] {
      check(errorCode(["id": 3, "op": "render", "source": inside.path, "output": output, "context": context, "size": ["kind": "preview", "maxDimension": 128]]) == "bad-path", "output \(output) not confined")
    }
    check(!FileManager.default.fileExists(atPath: "/tmp/film-lab-escape.jpg"), "escaped write")
    let good = response(["id": 4, "op": "render", "source": inside.path, "output": root.appendingPathComponent("ok.jpg").path, "context": context, "size": ["kind": "preview", "maxDimension": 128]])
    check(good["ok"] as? Bool == true && good["id"] as? Int == 4, "confined render must work: \(good)")
    check(errorCode(["id": 5, "op": "crash"]) == "unknown-op", "test hooks must be off by default")
    check(errorCode(["id": 6, "op": "render", "source": inside.path, "output": root.appendingPathComponent("x.jpg").path, "context": context, "size": ["kind": "preview", "maxDimension": 99_999]]) == "bad-request", "preview size bound")
    let garbage = try JSONSerialization.jsonObject(with: worker.handle(line: "not json")) as! [String: Any]
    check(garbage["ok"] as? Bool == false, "garbage line must fail cleanly")
  }

  mutating func imageInputs() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = root.appendingPathComponent("fake.jpg")
    try Data("not an image".utf8).write(to: text)
    check((try? LabImaging.inspect(text)) == nil, "text file accepted")
    let original = try Data(contentsOf: fixture("day-portrait"))
    let truncated = root.appendingPathComponent("truncated.png")
    try original.prefix(200).write(to: truncated)
    check((try? LabImaging.renderJPEG(source: truncated, recipe: LabImaging.originalRecipe, renderSize: .preview(maxPixelDimension: 64), quality: 0.8)) == nil, "truncated PNG rendered")
    // Cut after the header: ImageIO would decode the top rows and grey-fill
    // the rest, so an incomplete file must be refused at inspection.
    let fullJPEG = root.appendingPathComponent("full.jpg")
    try Self.write(try Self.cgImage(fixture("day-portrait")), to: fullJPEG, type: "public.jpeg")
    let jpeg = try Data(contentsOf: fullJPEG)
    check((try? LabImaging.inspect(fullJPEG)) != nil, "complete JPEG rejected")
    for (name, data) in [
      ("half.png", original.prefix(original.count / 2)),
      ("half.jpg", jpeg.prefix(jpeg.count / 2)),
    ] {
      let url = root.appendingPathComponent(name)
      try Data(data).write(to: url)
      check((try? LabImaging.inspect(url)) == nil, "incomplete \(name) accepted")
    }
    let gif = root.appendingPathComponent("image.gif")
    try Self.write(try Self.cgImage(fixture("day-portrait")), to: gif, type: "com.compuserve.gif")
    do {
      _ = try LabImaging.inspect(gif)
      check(false, "GIF accepted")
    } catch let error as LabError {
      check(error.code == "unsupported-image", "GIF error code \(error.code)")
    }
    do {
      _ = try LabImaging.inspect(fixture("day-portrait"), maximumPixels: 100_000)
      check(false, "pixel budget not enforced")
    } catch let error as LabError {
      check(error.code == "image-too-large", "pixel budget code \(error.code)")
    }
    let heic = root.appendingPathComponent("image.heic")
    try Self.write(try Self.cgImage(fixture("day-portrait")), to: heic, type: "public.heic")
    let info = try LabImaging.inspect(heic)
    check(info.typeIdentifier == "public.heic" && info.width == 1024 && info.height == 682, "HEIC inspect \(info)")
    let rendered = try LabImaging.renderJPEG(source: heic, recipe: LabRecipeBuilder.build(controls: .empty, context: defaultContext), renderSize: .full, quality: 0.92)
    check(rendered.width == 1024 && rendered.height == 682, "HEIC render size")
  }

  mutating func orientationAndColour() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // A Display P3 JPEG stored rotated 90° anticlockwise, tagged EXIF orientation 6, with GPS.
    let source = try Self.cgImage(fixture("day-portrait"))
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(data: nil, width: source.height, height: source.width, bitsPerComponent: 8, bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: CGFloat(source.height), y: 0)
    context.rotate(by: .pi / 2)
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    let rotated = context.makeImage()!
    let url = root.appendingPathComponent("p3.jpg")
    try Self.write(rotated, to: url, type: "public.jpeg", properties: [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N"],
    ])
    let info = try LabImaging.inspect(url)
    check(info.orientation == 6 && info.width == 1024 && info.height == 682, "oriented dimensions \(info)")
    check((info.profileName ?? "").contains("P3"), "P3 profile expected, got \(info.profileName ?? "nil")")
    let original = try LabImaging.renderJPEG(source: url, recipe: LabImaging.originalRecipe, renderSize: .preview(maxPixelDimension: 512), quality: 0.9)
    check(original.width == 512 && original.height == 341, "original preview must be upright \(original.width)x\(original.height)")
    let output = CGImageSourceCreateWithData(original.data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as! [CFString: Any]
    check(properties[kCGImagePropertyGPSDictionary] == nil, "GPS leaked into output")
    check((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "output orientation must be up")
    check((properties[kCGImagePropertyProfileName] as? String ?? "").contains("sRGB"), "output must be sRGB tagged, got \(properties[kCGImagePropertyProfileName] ?? "nil")")
    // Same orientation as the upright fixture: compare rendered pixels.
    let upright = try LabImaging.renderRGBA(source: fixture("day-portrait"), recipe: LabImaging.originalRecipe, renderSize: .preview(maxPixelDimension: 512))
    let turned = try LabImaging.renderRGBA(source: url, recipe: LabImaging.originalRecipe, renderSize: .preview(maxPixelDimension: 512))
    let difference = turned.difference(from: upright)
    check(difference != nil && difference!.mean < 6, "oriented P3 original must match the upright sRGB source (mean \(difference?.mean ?? -1))")
  }

  mutating func sameSizeFidelity() throws {
    for name in Self.fixtureNames {
      let url = fixture(name)
      for (controls, seed) in [(ValidatedControls.empty, seed(leak: true)), (try schema.validate(["contrast": .number(0.4), "grainSize": .number(2)]), 20_260_915)] {
        let applied = LabRecipeBuilder.build(controls: controls, context: context(seed: seed))
        for size in [FilmRenderSize.preview(maxPixelDimension: 256), .preview(maxPixelDimension: 1024), .full] {
          // Direct: the app's own still path on the shared processor.
          let data = try Data(contentsOf: url)
          let directImage = try FilmProcessor.shared.process(data, recipe: applied, renderSize: size)
          let directJPEG = try FilmProcessor.shared.encodedData(directImage, format: .jpeg, quality: 0.92)
          let helper = try LabImaging.renderJPEG(source: url, recipe: applied, renderSize: size, quality: 0.92)
          check(helper.data == directJPEG, "\(name) \(size.kind) helper JPEG differs from direct encodedData")
          let directCG = try Self.awaitRender(CIImage(cgImage: try Self.cgImage(url)), recipe: applied, size: size)
          let helperRGBA = try LabImaging.renderRGBA(source: url, recipe: applied, renderSize: size)
          let difference = helperRGBA.difference(from: try LabBitmap(directCG))
          check(difference?.maximum == 0, "\(name) \(size.kind) helper pixels differ from renderedCGImage (max \(difference?.maximum ?? -1))")
        }
      }
    }
  }

  // MARK: - Helpers

  static func awaitRender(_ image: CIImage, recipe: AppliedFilmRecipe, size: FilmRenderSize) throws -> CGImage {
    let box = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      do {
        box.set(.success(try await FilmProcessor.shared.renderedCGImage(image, recipe: recipe, renderSize: size)))
      } catch {
        box.set(.failure(error))
      }
      semaphore.signal()
    }
    semaphore.wait()
    return try box.get()
  }

  final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CGImage, Error> = .failure(LabError("pending", "pending"))
    func set(_ value: Result<CGImage, Error>) { lock.withLock { result = value } }
    func get() throws -> CGImage { try lock.withLock { try result.get() } }
  }

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("film-lab-selftest-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
  }

  static func cgImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw LabError("decode-failed", "Cannot decode \(url.lastPathComponent).") }
    return image
  }

  static func write(_ image: CGImage, to url: URL, type: String, properties: [CFString: Any] = [:]) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
      throw LabError("encode-failed", "No encoder for \(type).")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw LabError("encode-failed", "Cannot finalize \(type).")
    }
  }
}
