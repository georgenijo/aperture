import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import Aperture

/// Issue #18: developed JPEGs should retain the camera's capture metadata
/// (EXIF/TIFF/GPS, DateTimeOriginal) while dropping cues that described the
/// original, un-rendered pixels rather than the developed ones (orientation,
/// pixel dimensions) and never embedding a thumbnail.
final class FilmExportTests: XCTestCase {

  func testEncodedDataCopiesCaptureMetadataOntoRenderedPixels() throws {
    let sourceData = try makeSourceJPEGWithMetadata()
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let recipe = makeAppliedRecipe()

    let image = try processor.process(sourceData, recipe: recipe)
    let encoded = try processor.encodedData(image, format: .jpeg, metadataSource: sourceData)

    guard let outSource = CGImageSourceCreateWithData(encoded as CFData, nil) else {
      return XCTFail("Could not decode encoded output")
    }
    XCTAssertEqual(CGImageSourceGetCount(outSource), 1)

    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any])

    let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:09:15 13:15:00")
    let exposureTime = try XCTUnwrap(exif[kCGImagePropertyExifExposureTime] as? Double)
    XCTAssertEqual(exposureTime, 0.008, accuracy: 0.0005)

    let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
    XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Apple")
    XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "iPhone")

    // The render is always upright, whatever orientation the camera capture
    // carried (this fixture uses 6 / rotated 90deg CW).
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    XCTAssertEqual(orientation, 1)

    guard let outImage = CGImageSourceCreateImageAtIndex(outSource, 0, nil) else {
      return XCTFail("Could not decode encoded output image")
    }
    // Pixel dimensions must describe the rendered image, not the original
    // capture (which had swapped width/height under orientation 6).
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, outImage.width)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, outImage.height)
    if let exifWidth = exif[kCGImagePropertyExifPixelXDimension] as? Int {
      XCTAssertEqual(exifWidth, outImage.width)
    }
    if let exifHeight = exif[kCGImagePropertyExifPixelYDimension] as? Int {
      XCTAssertEqual(exifHeight, outImage.height)
    }

    // No embedded thumbnail: kCGImageDestinationEmbedThumbnail is always
    // false for JPEG output. `CGImageSourceCreateThumbnailAtIndex` is not a
    // reliable probe for this on this SDK -- empirically it still
    // synthesizes a thumbnail from the full image even when
    // `kCGImageSourceCreateThumbnailFromImageIfAbsent` is false and no
    // thumbnail is embedded, for both embedded-thumbnail and
    // no-embedded-thumbnail fixtures alike. Instead check the file itself:
    // an embedded EXIF thumbnail is a second complete JPEG stream (its own
    // SOI marker) inside the APP1 segment, so a JPEG with no embedded
    // thumbnail has exactly one `FFD8` marker pair.
    XCTAssertFalse(Self.hasEmbeddedJPEGThumbnail(encoded))
  }

  func testEncodedDataWithoutMetadataSourceCarriesNoCaptureMetadata() throws {
    let sourceData = try makeSourceJPEGWithMetadata()
    let processor = FilmProcessor(context: CIContext(options: [.useSoftwareRenderer: true]))
    let recipe = makeAppliedRecipe()

    let image = try processor.process(sourceData, recipe: recipe)
    let encoded = try processor.encodedData(image, format: .jpeg)

    guard let outSource = CGImageSourceCreateWithData(encoded as CFData, nil) else {
      return XCTFail("Could not decode encoded output")
    }
    let properties =
      CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])

    XCTAssertFalse(Self.hasEmbeddedJPEGThumbnail(encoded))
  }

  // MARK: - Fixtures

  private func makeAppliedRecipe() -> AppliedFilmRecipe {
    FilmRecipeCatalog.legacyOriginal.resolve(
      seed: 7,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      options: FilmProcessingOptions(
        lightLeaksEnabled: false,
        dateStamp: .off
      ),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
  }

  /// A small JPEG with a DateTimeOriginal/ExposureTime EXIF payload, a
  /// TIFF Make/Model, and orientation 6 -- standing in for a camera capture.
  private func makeSourceJPEGWithMetadata() throws -> Data {
    let width = 64
    let height = 48
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else {
      throw XCTSkip("Could not create bitmap context for fixture")
    }
    context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = try XCTUnwrap(context.makeImage())

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, "public.jpeg" as CFString, 1, nil)
    else {
      throw XCTSkip("Could not create destination for fixture")
    }

    let exif: [CFString: Any] = [
      kCGImagePropertyExifDateTimeOriginal: "2026:09:15 13:15:00",
      kCGImagePropertyExifExposureTime: 0.008,
    ]
    let tiff: [CFString: Any] = [
      kCGImagePropertyTIFFMake: "Apple",
      kCGImagePropertyTIFFModel: "iPhone",
    ]
    let properties: [CFString: Any] = [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyExifDictionary: exif,
      kCGImagePropertyTIFFDictionary: tiff,
    ]
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// Counts complete JPEG streams (`FFD8` start-of-image marker pairs) in
  /// `data`. Baseline JPEG entropy-coded scan data byte-stuffs any literal
  /// `FF` byte with a following `00`, so a genuine `FFD8` marker pair only
  /// ever occurs at a real stream boundary: the outer image, plus one per
  /// embedded thumbnail stream (e.g. the EXIF APP1 thumbnail).
  private static func hasEmbeddedJPEGThumbnail(_ data: Data) -> Bool {
    var markerCount = 0
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      let bytes = buffer.bindMemory(to: UInt8.self)
      var index = 0
      while index < bytes.count - 1 {
        if bytes[index] == 0xFF, bytes[index + 1] == 0xD8 {
          markerCount += 1
          index += 2
        } else {
          index += 1
        }
      }
    }
    return markerCount > 1
  }
}
