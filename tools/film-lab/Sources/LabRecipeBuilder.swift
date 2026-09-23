import Foundation

/// The shipping recipe resolved for one context, plus what the handlers
/// need to know about it.
struct LabBaseline: Sendable {
  let recipe: FilmRecipe
  let resolved: AppliedFilmRecipe
}

/// A mutable copy of a resolved recipe. Handlers edit stages in place so the
/// shipping stage order is preserved and no stage is ever added.
struct LabWorkingRecipe: Sendable {
  var stages: [FilmStage]
  var lightLeakApplied: Bool
  var dateStampHidden = false

  mutating func updateResponse(_ body: (inout FilmResponseStage) -> Void) {
    for index in stages.indices {
      if case .filmResponse(var response) = stages[index] {
        body(&response)
        stages[index] = .filmResponse(response)
      }
    }
  }

  mutating func updateHalation(_ body: (inout HalationStage) -> Void) {
    for index in stages.indices {
      if case .halation(var stage) = stages[index] {
        body(&stage)
        stages[index] = .halation(stage)
      }
    }
  }

  mutating func updateSoftness(_ body: (inout SoftnessStage) -> Void) {
    for index in stages.indices {
      if case .softness(var stage) = stages[index] {
        body(&stage)
        stages[index] = .softness(stage)
      }
    }
  }

  mutating func updateAberration(_ body: (inout ChromaticAberrationStage) -> Void) {
    for index in stages.indices {
      if case .chromaticAberration(var stage) = stages[index] {
        body(&stage)
        stages[index] = .chromaticAberration(stage)
      }
    }
  }

  mutating func updateGrain(_ body: (inout GrainStage) -> Void) {
    for index in stages.indices {
      if case .grain(var stage) = stages[index] {
        body(&stage)
        stages[index] = .grain(stage)
      }
    }
  }

  mutating func updateLeak(_ body: (inout LightLeakStage) -> Void) {
    for index in stages.indices {
      if case .lightLeak(var stage) = stages[index] {
        body(&stage)
        stages[index] = .lightLeak(stage)
      }
    }
  }

  mutating func updateVignette(_ body: (inout VignetteStage) -> Void) {
    for index in stages.indices {
      if case .vignette(var stage) = stages[index] {
        body(&stage)
        stages[index] = .vignette(stage)
      }
    }
  }
}

/// Exactly one handler per declared control; `LabSelfTests` checks the ids
/// against `controls.json` in both directions. Handlers run in this array's
/// order, which is therefore the documented composition order.
struct LabControlHandler: Sendable {
  let id: String
  let apply: @Sendable (inout LabWorkingRecipe, LabControlValue, LabBaseline) -> Void
}

enum LabRecipeBuilder {
  static let baseRecipe = FilmRecipeCatalog.nineteenNinetyEight

  /// Resolves the shipping recipe exactly as a capture would: the app's
  /// default leak setting, the explicit context, and no injected stages.
  /// The 1998 recipe forces its own seven-segment stamp configuration, so
  /// the `dateStamp` option passed here is ignored by `resolve`.
  static func baseline(for context: LabContext) -> LabBaseline {
    let options = FilmProcessingOptions(
      lightLeaksEnabled: AppSettings.defaults.lightLeaksEnabled,
      dateStamp: AppSettings.defaults.dateStamp,
      photoQuality: context.photoQuality)
    return LabBaseline(
      recipe: baseRecipe,
      resolved: baseRecipe.resolve(
        seed: context.seed, capturedAt: context.capturedAt, options: options,
        timeZone: context.timeZone))
  }

  static func build(controls: ValidatedControls, context: LabContext) -> AppliedFilmRecipe {
    build(controls: controls, baseline: baseline(for: context))
  }

  static func build(controls: ValidatedControls, baseline: LabBaseline) -> AppliedFilmRecipe {
    // Reset is exact: with nothing set, the direct resolution is returned.
    guard !controls.values.isEmpty else { return baseline.resolved }
    let resolved = baseline.resolved
    var working = LabWorkingRecipe(
      stages: resolved.stages, lightLeakApplied: resolved.resolvedSettings.lightLeakApplied)
    for handler in handlers {
      if let value = controls.values[handler.id] {
        handler.apply(&working, value, baseline)
      }
    }
    let settings = resolved.resolvedSettings
    let resolvedSettings: FilmResolvedSettings
    if working.lightLeakApplied == settings.lightLeakApplied, !working.dateStampHidden {
      resolvedSettings = settings
    } else {
      resolvedSettings = FilmResolvedSettings(
        lightLeakApplied: working.lightLeakApplied,
        dateStampConfiguration: working.dateStampHidden ? .off : settings.dateStampConfiguration,
        dateStampText: working.dateStampHidden ? nil : settings.dateStampText,
        timeZoneIdentifier: settings.timeZoneIdentifier,
        compressionQuality: settings.compressionQuality)
    }
    return AppliedFilmRecipe(
      identifier: resolved.identifier,
      version: resolved.version,
      seed: resolved.seed,
      stages: working.stages,
      resolvedSettings: resolvedSettings)
  }

  // MARK: - Bounded monotone maps on [0, 1]

  /// `y^exponent`; fixes 0 and 1 and is monotone for any positive exponent.
  static func power(_ y: Double, _ exponent: Double) -> Double {
    guard y > 0 else { return 0 }
    guard y < 1 else { return 1 }
    return pow(y, exponent)
  }

  /// A symmetric S-curve through 0, 0.5 and 1: steeper through mid-grey
  /// when `exponent > 1`, flatter when below.
  static func sCurve(_ y: Double, _ exponent: Double) -> Double {
    let clamped = min(max(y, 0), 1)
    return clamped < 0.5
      ? 0.5 * pow(2 * clamped, exponent)
      : 1 - 0.5 * pow(2 * (1 - clamped), exponent)
  }

  static func mapCurves(
    _ response: inout FilmResponseStage, channels: [Int], _ transform: (Double) -> Double
  ) {
    for channel in channels where channel < response.curves.count {
      response.curves[channel] = response.curves[channel].map(transform)
    }
  }

  // MARK: - Handlers

  static let handlers: [LabControlHandler] = [
    // Tone and colour: copies of the fitted response's own parameters.
    LabControlHandler(id: "crosstalk") { working, value, _ in
      guard case .number(let strength) = value else { return }
      let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
      working.updateResponse { response in
        response.matrix = zip(response.matrix, identity).map { $1 + strength * ($0 - $1) }
      }
    },
    LabControlHandler(id: "brightness") { working, value, _ in
      guard case .number(let amount) = value else { return }
      let exponent = pow(2, -0.8 * amount)
      working.updateResponse { mapCurves(&$0, channels: [0, 1, 2]) { power($0, exponent) } }
    },
    LabControlHandler(id: "contrast") { working, value, _ in
      guard case .number(let amount) = value else { return }
      let exponent = pow(2, 0.8 * amount)
      working.updateResponse { mapCurves(&$0, channels: [0, 1, 2]) { sCurve($0, exponent) } }
    },
    LabControlHandler(id: "warmth") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateResponse { response in
        mapCurves(&response, channels: [0]) { power($0, pow(2, -0.3 * amount)) }
        mapCurves(&response, channels: [2]) { power($0, pow(2, 0.3 * amount)) }
      }
    },
    LabControlHandler(id: "chroma") { working, value, _ in
      guard case .number(let amount) = value else { return }
      let gain = pow(2, amount)
      working.updateResponse { response in
        response.saturation = response.saturation.map { $0 * gain }
        response.hueChroma = response.hueChroma.map { $0 * gain }
      }
    },
    LabControlHandler(id: "shadowChroma") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateResponse { $0.saturation[0] *= pow(2, amount) }
    },
    LabControlHandler(id: "highlightChroma") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateResponse { $0.saturation[2] *= pow(2, amount) }
    },
    LabControlHandler(id: "hueChroma") { working, value, _ in
      guard case .number(let strength) = value else { return }
      working.updateResponse { $0.hueChroma = $0.hueChroma.map { $0 * strength } }
    },
    LabControlHandler(id: "hueRotate") { working, value, _ in
      guard case .number(let strength) = value else { return }
      working.updateResponse { $0.hueRotate = $0.hueRotate.map { $0 * strength } }
    },
    LabControlHandler(id: "hueLightness") { working, value, _ in
      guard case .number(let strength) = value else { return }
      working.updateResponse { $0.hueLight = $0.hueLight.map { $0 * strength } }
    },

    // Optics and texture: stage amounts, in shipping stage order.
    LabControlHandler(id: "halation") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateHalation { $0.amount = amount }
    },
    LabControlHandler(id: "softness") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateSoftness { $0.amount = amount }
    },
    LabControlHandler(id: "fringing") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateAberration { $0.amount = amount }
    },
    LabControlHandler(id: "grainAmount") { working, value, baseline in
      guard case .number(let amount) = value else { return }
      // The control is the recipe's base amount; keep this seed's jitter.
      // Zero is the toggle's "off" value and must stay exactly off.
      let jitter = (baseline.resolved.grain?.amount ?? 0) - (baseline.recipe.stages.grain?.amount ?? 0)
      working.updateGrain { $0.amount = amount <= 0 ? 0 : min(max(amount + jitter, 0), 1) }
    },
    LabControlHandler(id: "grainSize") { working, value, _ in
      guard case .number(let size) = value else { return }
      working.updateGrain { $0.size = size }
    },
    LabControlHandler(id: "vignette") { working, value, _ in
      guard case .number(let amount) = value else { return }
      working.updateVignette { $0.amount = amount }
    },
    // Must run before `lightLeakStrength`, which scales whatever leak this leaves.
    LabControlHandler(id: "lightLeak") { working, value, baseline in
      guard case .choice(let mode) = value else { return }
      switch mode {
      case "off":
        working.lightLeakApplied = false
        working.updateLeak {
          $0.probability = 0
          $0.strength = 0
        }
      case "on" where !working.lightLeakApplied:
        // The seed drew no leak (and so no strength jitter): restore the
        // recipe's own probability and strength so the decision draws one.
        guard let recipeLeak = baseline.recipe.stages.lightLeak,
          recipeLeak.probability > 0, recipeLeak.strength > 0
        else { return }
        working.lightLeakApplied = true
        working.updateLeak {
          $0.probability = recipeLeak.probability
          $0.strength = recipeLeak.strength
        }
      default:
        break
      }
    },
    LabControlHandler(id: "lightLeakStrength") { working, value, baseline in
      guard case .number(let strength) = value, working.lightLeakApplied else { return }
      let recipeStrength = baseline.recipe.stages.lightLeak?.strength ?? 0
      let seededScale =
        baseline.resolved.resolvedSettings.lightLeakApplied && recipeStrength > 0
        ? (baseline.resolved.lightLeak?.strength ?? 0) / recipeStrength
        : 1
      let effective = min(max(strength * seededScale, 0), 1)
      if effective > 0 {
        working.updateLeak { $0.strength = effective }
      } else {
        working.lightLeakApplied = false
        working.updateLeak {
          $0.probability = 0
          $0.strength = 0
        }
      }
    },

    LabControlHandler(id: "dateStamp") { working, value, _ in
      guard case .choice(let mode) = value, mode == "off" else { return }
      working.dateStampHidden = true
    },
  ]
}
