import CoreGraphics
import CoreImage

extension FilmProcessor {
  func applyToneCurve(_ image: CIImage, parameters: FilmParameters, extent: CGRect) -> CIImage {
    guard let filter = CIFilter(name: "CIToneCurve") else { return image }
    let rolloff = CGFloat(parameters.highlightRolloff)
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
    filter.setValue(CIVector(x: 0.25, y: 0.25 - rolloff * 0.02), forKey: "inputPoint1")
    filter.setValue(
      CIVector(x: 0.50, y: 0.50 + CGFloat(parameters.contrast - 1) * 0.12), forKey: "inputPoint2")
    filter.setValue(CIVector(x: 0.75, y: 0.76 - rolloff * 0.10), forKey: "inputPoint3")
    filter.setValue(CIVector(x: 1, y: 1 - rolloff * 0.16), forKey: "inputPoint4")
    return filter.outputImage?.cropped(to: extent) ?? image
  }

  func applyColorResponse(_ image: CIImage, parameters: FilmParameters, extent: CGRect) -> CIImage {
    var output = image
    if let controls = CIFilter(name: "CIColorControls") {
      controls.setValue(output, forKey: kCIInputImageKey)
      controls.setValue(parameters.saturation, forKey: kCIInputSaturationKey)
      controls.setValue(parameters.contrast, forKey: kCIInputContrastKey)
      controls.setValue(parameters.exposure * 0.25, forKey: kCIInputBrightnessKey)
      output = controls.outputImage?.cropped(to: extent) ?? output
    }

    if let warmth = CIFilter(name: "CIColorMatrix") {
      let warm = CGFloat(parameters.warmth)
      let cool = CGFloat(parameters.shadowCoolness)
      warmth.setValue(output, forKey: kCIInputImageKey)
      warmth.setValue(CIVector(x: 1 + warm * 0.08, y: 0, z: 0, w: 0), forKey: "inputRVector")
      warmth.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
      warmth.setValue(
        CIVector(x: 0, y: 0, z: 1 - warm * 0.07 + cool * 0.04, w: 0), forKey: "inputBVector")
      warmth.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
      output = warmth.outputImage?.cropped(to: extent) ?? output
    }
    return output
  }

  func applyBloom(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
    guard amount > 0.001,
      let bloom = CIFilter(name: "CIBloom")
    else { return image }
    bloom.setValue(image, forKey: kCIInputImageKey)
    bloom.setValue(min(1, amount * 0.75), forKey: kCIInputIntensityKey)
    bloom.setValue(max(1, extent.width * 0.012 * CGFloat(amount)), forKey: kCIInputRadiusKey)
    guard var bloomImage = bloom.outputImage?.cropped(to: extent) else { return image }
    if let warm = CIFilter(name: "CIColorMatrix") {
      let warmth = CGFloat(amount)
      warm.setValue(bloomImage, forKey: kCIInputImageKey)
      warm.setValue(CIVector(x: 1 + warmth * 0.20, y: 0, z: 0, w: 0), forKey: "inputRVector")
      warm.setValue(CIVector(x: 0, y: 1 + warmth * 0.04, z: 0, w: 0), forKey: "inputGVector")
      warm.setValue(CIVector(x: 0, y: 0, z: 1 - warmth * 0.10, w: 0), forKey: "inputBVector")
      warm.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
      bloomImage = warm.outputImage?.cropped(to: extent) ?? bloomImage
    }
    return blend(
      bloomImage, over: image, opacity: min(0.42, CGFloat(amount) * 0.50), extent: extent)
  }

  func applySoftness(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
    guard amount > 0.001,
      let blur = CIFilter(name: "CIGaussianBlur")
    else { return image }
    blur.setValue(image, forKey: kCIInputImageKey)
    blur.setValue(max(0.15, extent.width * 0.0022 * CGFloat(amount)), forKey: kCIInputRadiusKey)
    guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }
    return blend(blurred, over: image, opacity: min(0.28, CGFloat(amount) * 0.42), extent: extent)
  }

  func applyChromaticAberration(
    _ image: CIImage,
    amount: Double,
    decision: FilmProcessingDecision,
    extent: CGRect
  ) -> CIImage {
    guard amount > 0.0005 else { return image }
    let shift = max(0.15, min(extent.width, extent.height) * 0.0022 * CGFloat(amount))
    let red = shift * CGFloat(decision.redChannelShift)
    let blue = shift * CGFloat(decision.blueChannelShift)
    // Native channel filters avoid source-compiled CIColorKernel use while
    // retaining restrained, deterministic chromatic separation.
    guard
      let redChannel = Self.shiftedChannel(
        image, channel: .red, translationX: -red, extent: extent),
      let greenChannel = Self.shiftedChannel(
        image, channel: .green, translationX: 0, extent: extent),
      let blueChannel = Self.shiftedChannel(
        image, channel: .blue, translationX: blue, extent: extent),
      let redGreen = Self.mergeChannels(redChannel, with: greenChannel, extent: extent),
      let output = Self.mergeChannels(blueChannel, with: redGreen, extent: extent)
    else {
      return image
    }
    return output
  }

  func applyGrain(
    _ image: CIImage,
    amount: Double,
    size: Double,
    seed: UInt64,
    extent: CGRect
  ) -> CIImage {
    guard amount > 0.001,
      let noise = Self.makeNoiseImage(extent: extent, grainSize: size, seed: seed)
    else { return image }
    guard let noiseMatrix = CIFilter(name: "CIColorMatrix"),
      let luminanceMatrix = CIFilter(name: "CIColorMatrix"),
      let luminanceCurve = CIFilter(name: "CIColorPolynomial"),
      let maskedNoise = CIFilter(name: "CIBlendWithMask"),
      let added = CIFilter(name: "CIAdditionCompositing")
    else { return image }

    let gain = CGFloat(min(1, amount) * 0.23)
    noiseMatrix.setValue(noise, forKey: kCIInputImageKey)
    noiseMatrix.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
    noiseMatrix.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
    noiseMatrix.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
    noiseMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    noiseMatrix.setValue(
      CIVector(x: -gain * 0.5, y: -gain * 0.5, z: -gain * 0.5, w: 0), forKey: "inputBiasVector")
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

    // 0.25 + 3L - 3L²: strongest around midtones, restrained at ends.
    luminanceCurve.setValue(luminanceImage, forKey: kCIInputImageKey)
    let coefficients = CIVector(x: 0.25, y: 3, z: -3, w: 0)
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
    extent: CGRect
  ) -> CIImage {
    guard
      let overlay = Self.makeLightLeakImage(extent: extent, decision: decision, strength: strength),
      let composite = CIFilter(name: "CISourceOverCompositing")
    else { return image }
    composite.setValue(overlay, forKey: kCIInputImageKey)
    composite.setValue(image, forKey: kCIInputBackgroundImageKey)
    return composite.outputImage?.cropped(to: extent) ?? image
  }

  func applyVignette(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
    guard amount > 0.001,
      let vignette = CIFilter(name: "CIVignette")
    else { return image }
    vignette.setValue(image, forKey: kCIInputImageKey)
    vignette.setValue(min(1, amount * 0.74), forKey: kCIInputIntensityKey)
    vignette.setValue(max(0.1, min(extent.width, extent.height) * 0.68), forKey: kCIInputRadiusKey)
    return vignette.outputImage?.cropped(to: extent) ?? image
  }

  func applyDateStamp(_ image: CIImage, text: String, extent: CGRect) -> CIImage {
    guard let stamp = FilmOverlayFactory.dateStampImage(text: text, extent: extent),
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

  private static func shiftedChannel(
    _ image: CIImage,
    channel: Channel,
    translationX: CGFloat,
    extent: CGRect
  ) -> CIImage? {
    guard let transform = CIFilter(name: "CIAffineTransform"),
      let matrix = CIFilter(name: "CIColorMatrix")
    else { return nil }
    transform.setValue(image, forKey: kCIInputImageKey)
    transform.setValue(
      CGAffineTransform(translationX: translationX, y: 0), forKey: kCIInputTransformKey)
    guard let shifted = transform.outputImage else { return nil }
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
