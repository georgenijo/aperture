import CoreGraphics
import CoreImage

/// The colour stage shared by stills and video: `FilmColorModel` baked into
/// a native `CIColorCube`, so both paths grade identically and the whole
/// tone/colour chain costs one texture lookup per pixel.
enum FilmColorCube {
  static let dimension = 32

  /// Generating the table is the expensive part; build it once per render or
  /// export. The `Data` is immutable, so video frames rendered concurrently
  /// can each wrap it in their own filter.
  static func data(grade: FilmColorGrade) -> Data {
    FilmColorModel.cubeData(dimension: dimension, grade: grade)
  }

  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

  static func apply(_ image: CIImage, cubeData: Data, extent: CGRect) -> CIImage {
    guard let cube = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
    cube.setValue(image, forKey: kCIInputImageKey)
    cube.setValue(dimension, forKey: "inputCubeDimension")
    cube.setValue(cubeData, forKey: "inputCubeData")
    // The model is defined on sRGB-encoded values; Core Image otherwise
    // looks the table up in its linear working space.
    if let sRGB { cube.setValue(sRGB, forKey: "inputColorSpace") }
    return cube.outputImage?.cropped(to: extent) ?? image
  }
}

extension FilmProcessor {
  func applyColorGrade(_ image: CIImage, grade: FilmColorGrade, extent: CGRect) -> CIImage {
    FilmColorCube.apply(image, cubeData: FilmColorCube.data(grade: grade), extent: extent)
  }

  func applyHalation(_ image: CIImage, stage: HalationStage, extent: CGRect) -> CIImage {
    guard stage.amount > stage.minimumAmount,
      let bloom = CIFilter(name: "CIBloom")
    else { return image }
    bloom.setValue(image, forKey: kCIInputImageKey)
    bloom.setValue(
      min(stage.intensityCap, stage.amount * stage.intensityScale), forKey: kCIInputIntensityKey)
    let radius: CGFloat =
      stage.radiusScalesWithAmount
      ? max(
        CGFloat(stage.minimumRadius),
        extent.width * CGFloat(stage.radiusScale) * CGFloat(stage.amount))
      : max(CGFloat(stage.minimumRadius), extent.width * CGFloat(stage.radiusScale))
    bloom.setValue(radius, forKey: kCIInputRadiusKey)
    guard var bloomImage = bloom.outputImage?.cropped(to: extent) else { return image }
    if let tintFilter = CIFilter(name: "CIColorMatrix") {
      let (redDiagonal, greenDiagonal, blueDiagonal): (CGFloat, CGFloat, CGFloat)
      switch stage.tint {
      case .warmByAmount(let red, let green, let blue):
        let warmth = CGFloat(stage.amount)
        redDiagonal = 1 + warmth * CGFloat(red)
        greenDiagonal = 1 + warmth * CGFloat(green)
        blueDiagonal = 1 - warmth * CGFloat(blue)
      case .fixed(let red, let green, let blue):
        redDiagonal = CGFloat(red)
        greenDiagonal = CGFloat(green)
        blueDiagonal = CGFloat(blue)
      }
      tintFilter.setValue(bloomImage, forKey: kCIInputImageKey)
      tintFilter.setValue(CIVector(x: redDiagonal, y: 0, z: 0, w: 0), forKey: "inputRVector")
      tintFilter.setValue(CIVector(x: 0, y: greenDiagonal, z: 0, w: 0), forKey: "inputGVector")
      tintFilter.setValue(CIVector(x: 0, y: 0, z: blueDiagonal, w: 0), forKey: "inputBVector")
      tintFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
      bloomImage = tintFilter.outputImage?.cropped(to: extent) ?? bloomImage
    }
    return blend(
      bloomImage, over: image,
      opacity: min(
        CGFloat(stage.blendOpacityCap), CGFloat(stage.amount) * CGFloat(stage.blendOpacityScale)),
      extent: extent)
  }

  func applySoftness(_ image: CIImage, stage: SoftnessStage, extent: CGRect) -> CIImage {
    guard stage.amount > stage.minimumAmount else { return image }

    if stage.kind == .gaussian {
      return applyGaussianSoftness(image, stage: stage, extent: extent)
    }

    // Cheap plastic lenses stay reasonably sharp in the centre but smear
    // detail radially near the frame edges. A global Gaussian blur looked
    // merely out of focus and erased the disposable-camera character.
    let shortestSide = min(extent.width, extent.height)
    let centre = CIVector(x: extent.midX, y: extent.midY)
    guard let zoomBlur = CIFilter(name: "CIZoomBlur") else { return image }
    zoomBlur.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
    zoomBlur.setValue(centre, forKey: kCIInputCenterKey)
    zoomBlur.setValue(
      shortestSide * CGFloat(stage.zoomBlurScale) * CGFloat(stage.amount),
      forKey: kCIInputAmountKey)
    guard let softened = zoomBlur.outputImage?.cropped(to: extent) else { return image }

    guard let radial = CIFilter(name: "CIRadialGradient"),
      let masked = CIFilter(name: "CIBlendWithMask")
    else {
      return blend(
        softened, over: image,
        opacity: min(
          CGFloat(stage.fallbackBlendOpacityCap),
          CGFloat(stage.amount) * CGFloat(stage.fallbackBlendOpacityScale)),
        extent: extent)
    }
    radial.setValue(centre, forKey: kCIInputCenterKey)
    radial.setValue(shortestSide * CGFloat(stage.innerRadiusScale), forKey: "inputRadius0")
    radial.setValue(shortestSide * CGFloat(stage.outerRadiusScale), forKey: "inputRadius1")
    radial.setValue(CIColor.black, forKey: "inputColor0")
    radial.setValue(CIColor.white, forKey: "inputColor1")
    guard let edgeMask = radial.outputImage?.cropped(to: extent) else { return image }
    masked.setValue(softened, forKey: kCIInputImageKey)
    masked.setValue(image, forKey: kCIInputBackgroundImageKey)
    masked.setValue(edgeMask, forKey: kCIInputMaskImageKey)
    return masked.outputImage?.cropped(to: extent) ?? image
  }

  /// An isotropic Gaussian blur, uniform across the whole frame (unlike
  /// `.radialZoom`, which is strongest away from centre).
  private func applyGaussianSoftness(_ image: CIImage, stage: SoftnessStage, extent: CGRect)
    -> CIImage
  {
    let shortestSide = min(extent.width, extent.height)
    let radius = shortestSide * CGFloat(stage.gaussianRadiusScale) * CGFloat(stage.amount)
    guard radius >= 0.05, let gaussianBlur = CIFilter(name: "CIGaussianBlur") else { return image }
    gaussianBlur.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
    gaussianBlur.setValue(radius, forKey: kCIInputRadiusKey)
    return gaussianBlur.outputImage?.cropped(to: extent) ?? image
  }

  func applyChromaticAberration(
    _ image: CIImage,
    stage: ChromaticAberrationStage,
    decision: FilmProcessingDecision,
    extent: CGRect
  ) -> CIImage {
    guard stage.amount > stage.minimumAmount else { return image }
    let direction: CGFloat = stage.seeded ? (decision.seed & 1 == 0 ? 1 : -1) : 1
    let redChannelShift = stage.seeded ? decision.redChannelShift : 1
    let blueChannelShift = stage.seeded ? decision.blueChannelShift : 1
    let redScale =
      1 + CGFloat(stage.redGain) * CGFloat(stage.amount) * CGFloat(redChannelShift)
    let blueScale =
      1 + CGFloat(stage.blueGain) * CGFloat(stage.amount) * CGFloat(blueChannelShift)
    let lateralShift =
      min(extent.width, extent.height) * CGFloat(stage.lateralShiftScale) * CGFloat(stage.amount)
      * direction
    // Scale the red and blue records around the optical centre. Separation
    // increases toward the edges, unlike the old uniform horizontal shift.
    guard
      let redChannel = Self.transformedChannel(
        image, channel: .red, scale: redScale, translationX: -lateralShift, extent: extent),
      let greenChannel = Self.transformedChannel(
        image, channel: .green, scale: 1, translationX: 0, extent: extent),
      let blueChannel = Self.transformedChannel(
        image, channel: .blue, scale: blueScale, translationX: lateralShift, extent: extent),
      let redGreen = Self.mergeChannels(redChannel, with: greenChannel, extent: extent),
      let output = Self.mergeChannels(blueChannel, with: redGreen, extent: extent)
    else {
      return image
    }
    return output
  }

  func applyGrain(
    _ image: CIImage,
    stage: GrainStage,
    seed: UInt64,
    extent: CGRect
  ) -> CIImage {
    guard stage.amount > stage.minimumAmount,
      let noise = Self.makeNoiseImage(extent: extent, grainSize: stage.size, seed: seed)
    else { return image }
    guard let noiseMatrix = CIFilter(name: "CIColorMatrix"),
      let luminanceMatrix = CIFilter(name: "CIColorMatrix"),
      let luminanceCurve = CIFilter(name: "CIColorPolynomial"),
      let maskedNoise = CIFilter(name: "CIBlendWithMask"),
      let added = CIFilter(name: "CIAdditionCompositing")
    else { return image }

    let gain = CGFloat(min(stage.gainCap, stage.amount) * stage.gainScale)
    noiseMatrix.setValue(noise, forKey: kCIInputImageKey)
    noiseMatrix.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
    noiseMatrix.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
    noiseMatrix.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
    noiseMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    noiseMatrix.setValue(
      CIVector(
        x: -gain * CGFloat(stage.biasScale), y: -gain * CGFloat(stage.biasScale),
        z: -gain * CGFloat(stage.biasScale), w: 0), forKey: "inputBiasVector")
    guard let centeredNoise = noiseMatrix.outputImage?.cropped(to: extent) else { return image }

    luminanceMatrix.setValue(image, forKey: kCIInputImageKey)
    let luminance = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
    luminanceMatrix.setValue(luminance, forKey: "inputRVector")
    luminanceMatrix.setValue(luminance, forKey: "inputGVector")
    luminanceMatrix.setValue(luminance, forKey: "inputBVector")
    luminanceMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    guard let luminanceImage = luminanceMatrix.outputImage?.cropped(to: extent) else {
      return image
    }

    // constant + linear·L + quadratic·L²: strongest around midtones by
    // default, restrained at ends.
    luminanceCurve.setValue(luminanceImage, forKey: kCIInputImageKey)
    let coefficients = CIVector(
      x: CGFloat(stage.curveConstant), y: CGFloat(stage.curveLinear),
      z: CGFloat(stage.curveQuadratic), w: 0)
    luminanceCurve.setValue(coefficients, forKey: "inputRedCoefficients")
    luminanceCurve.setValue(coefficients, forKey: "inputGreenCoefficients")
    luminanceCurve.setValue(coefficients, forKey: "inputBlueCoefficients")
    guard let mask = luminanceCurve.outputImage?.cropped(to: extent) else { return image }

    maskedNoise.setValue(centeredNoise, forKey: kCIInputImageKey)
    maskedNoise.setValue(
      CIImage(color: .black).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
    maskedNoise.setValue(mask, forKey: kCIInputMaskImageKey)
    guard let grain = maskedNoise.outputImage?.cropped(to: extent) else { return image }
    added.setValue(grain, forKey: kCIInputImageKey)
    added.setValue(image, forKey: kCIInputBackgroundImageKey)
    return added.outputImage?.cropped(to: extent) ?? image
  }

  func applyLightLeak(
    _ image: CIImage,
    decision: LightLeakDecision,
    strength: Double,
    alphaCap: Double = 0.68,
    extent: CGRect
  ) -> CIImage {
    guard
      let overlay = Self.makeLightLeakImage(
        extent: extent, decision: decision, strength: strength, alphaCap: alphaCap),
      let composite = CIFilter(name: "CISourceOverCompositing")
    else { return image }
    composite.setValue(overlay, forKey: kCIInputImageKey)
    composite.setValue(image, forKey: kCIInputBackgroundImageKey)
    return composite.outputImage?.cropped(to: extent) ?? image
  }

  func applyVignette(_ image: CIImage, stage: VignetteStage, extent: CGRect) -> CIImage {
    guard stage.amount > stage.minimumAmount,
      let vignette = CIFilter(name: "CIVignette")
    else { return image }
    vignette.setValue(image, forKey: kCIInputImageKey)
    vignette.setValue(
      min(stage.intensityCap, stage.amount * stage.intensityScale), forKey: kCIInputIntensityKey)
    vignette.setValue(
      max(CGFloat(stage.minimumRadius), min(extent.width, extent.height) * CGFloat(stage.radiusScale)),
      forKey: kCIInputRadiusKey)
    return vignette.outputImage?.cropped(to: extent) ?? image
  }

  func applyDateStamp(
    _ image: CIImage, text: String, stage: DateStampStage = DateStampStage(), extent: CGRect
  ) -> CIImage {
    guard let stamp = FilmOverlayFactory.dateStampImage(text: text, extent: extent, stage: stage),
      let composite = CIFilter(name: "CISourceOverCompositing")
    else { return image }
    composite.setValue(stamp, forKey: kCIInputImageKey)
    composite.setValue(image, forKey: kCIInputBackgroundImageKey)
    return composite.outputImage?.cropped(to: extent) ?? image
  }

  func blend(_ foreground: CIImage, over background: CIImage, opacity: CGFloat, extent: CGRect)
    -> CIImage
  {
    guard let filter = CIFilter(name: "CIBlendWithMask") else { return background }
    let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: opacity)).cropped(
      to: extent)
    filter.setValue(foreground, forKey: kCIInputImageKey)
    filter.setValue(background, forKey: kCIInputBackgroundImageKey)
    filter.setValue(mask, forKey: kCIInputMaskImageKey)
    return filter.outputImage?.cropped(to: extent) ?? background
  }

  private enum Channel: Equatable {
    case red
    case green
    case blue
  }

  private static func transformedChannel(
    _ image: CIImage,
    channel: Channel,
    scale: CGFloat,
    translationX: CGFloat,
    extent: CGRect
  ) -> CIImage? {
    guard let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
    let transform = CGAffineTransform(
      a: scale,
      b: 0,
      c: 0,
      d: scale,
      tx: extent.midX * (1 - scale) + translationX,
      ty: extent.midY * (1 - scale)
    )
    let shifted = image.clampedToExtent().transformed(by: transform).cropped(to: extent)
    matrix.setValue(shifted, forKey: kCIInputImageKey)
    matrix.setValue(CIVector(x: channel == .red ? 1 : 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
    matrix.setValue(
      CIVector(x: 0, y: channel == .green ? 1 : 0, z: 0, w: 0), forKey: "inputGVector")
    matrix.setValue(CIVector(x: 0, y: 0, z: channel == .blue ? 1 : 0, w: 0), forKey: "inputBVector")
    matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    return matrix.outputImage?.cropped(to: extent)
  }

  private static func mergeChannels(_ image: CIImage, with background: CIImage, extent: CGRect)
    -> CIImage?
  {
    guard let filter = CIFilter(name: "CIMaximumCompositing") else { return nil }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(background, forKey: kCIInputBackgroundImageKey)
    return filter.outputImage?.cropped(to: extent)
  }
}
