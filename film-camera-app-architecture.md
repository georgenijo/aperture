# Film Camera App — Technical Architecture & Build Plan

## Vision

A modern iOS camera app with the aesthetic soul of Huji (film emulation, light leaks, date stamps, the "developing" ritual) but with the camera capabilities of a professional shooting tool: multi-lens switching, tap-to-focus/exposure, video mode, and multiple film stock presets.

**Post-capture processing only** — the viewfinder shows the raw camera feed, the magic happens after you press the shutter.

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────┐
│                        UI Layer                          │
│  SwiftUI App Shell                                       │
│  ├── CameraView (UIViewRepresentable wrapping AVF)       │
│  ├── LabView (gallery of developed photos)               │
│  ├── FilmPickerView (choose film stock preset)           │
│  └── SettingsView                                        │
├──────────────────────────────────────────────────────────┤
│                    Camera Engine                          │
│  AVFoundation                                            │
│  ├── AVCaptureSession (multi-input management)           │
│  ├── AVCaptureDevice (lens selection, focus, exposure)   │
│  ├── AVCapturePhotoOutput (stills)                       │
│  └── AVCaptureMovieFileOutput (video)                    │
├──────────────────────────────────────────────────────────┤
│                 Processing Pipeline                       │
│  Core Image + Metal                                      │
│  ├── FilmLUT (color grading per film stock)              │
│  ├── GrainKernel (Metal CIColorKernel)                   │
│  ├── LightLeakCompositor (overlay blending)              │
│  ├── ChromaticAberrationKernel (Metal CIWarpKernel)      │
│  ├── VignetteFilter (built-in CIVignette)                │
│  └── DateStampRenderer (Core Graphics text composite)    │
├──────────────────────────────────────────────────────────┤
│                   Storage Layer                           │
│  ├── FileManager (app sandbox for "undeveloped" photos)  │
│  ├── Photos Framework (export to camera roll)            │
│  └── Core Data or SwiftData (metadata, rolls, presets)   │
└──────────────────────────────────────────────────────────┘
```

---

## Module 1: Camera Engine (AVFoundation)

This is the heart of the app and where you differentiate from Huji. You're building a proper camera, not a toy.

### Multi-Lens Support

Modern iPhones expose multiple physical cameras as separate `AVCaptureDevice` instances. You switch between them by swapping the input on your capture session.

```swift
import AVFoundation

class CameraEngine: NSObject, ObservableObject {
    let session = AVCaptureSession()
    
    // Track available lenses
    private var availableDevices: [AVCaptureDevice] = []
    private var currentInput: AVCaptureDeviceInput?
    
    // Discover all back cameras
    func discoverLenses() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,   // 0.5x (13mm)
                .builtInWideAngleCamera,    // 1x   (26mm)
                .builtInTelephotoCamera,    // 2x/3x/5x depending on model
            ],
            mediaType: .video,
            position: .back
        )
        availableDevices = discoverySession.devices
        // Sort by focal length equivalent for clean UI ordering
    }
    
    // Switch lens — must reconfigure the session
    func switchToLens(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        
        // Remove current input
        if let currentInput = currentInput {
            session.removeInput(currentInput)
        }
        
        // Add new input
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentInput = newInput
            }
        } catch {
            print("Failed to switch lens: \(error)")
        }
        
        session.commitConfiguration()
    }
}
```

**Key considerations:**
- Not all iPhones have all lenses — always query `DiscoverySession` and build UI dynamically
- `builtInTripleCamera` or `builtInDualWideCamera` give you a virtual device that handles smooth zoom transitions, but you lose per-lens control. For a film camera app, discrete lens switching (0.5x → 1x → 2x buttons) feels more intentional and camera-like
- Lens switching takes ~100-200ms — show a brief transition animation to cover it
- Each lens has different aperture, sensor size, and noise characteristics — your film preset might need per-lens tuning

### Tap-to-Focus & Exposure

AVFoundation gives you precise control over focus and exposure points.

```swift
// Convert tap point from view coordinates to camera coordinates
func focusAndExpose(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
    guard let device = currentInput?.device else { return }
    
    // Convert screen point to camera coordinate space (0,0 to 1,1)
    let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
    
    do {
        try device.lockForConfiguration()
        
        // Focus
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus  // Focuses then locks
            // Or .continuousAutoFocus to keep tracking
        }
        
        // Exposure
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        
        device.unlockForConfiguration()
    } catch {
        print("Focus/exposure error: \(error)")
    }
}
```

**UX decisions to make:**
- Show a focus ring animation at the tap point (like the native camera app)
- After autofocus locks, should exposure stay locked too? (AE/AF lock on long press is a nice pattern)
- Consider a subtle exposure compensation slider (swipe up/down after tapping) — this is how Halide and ProCamera do it
- For the "film" vibe: maybe the focus ring is styled as an old-school split-prism or rangefinder indicator

### Photo Capture

```swift
private let photoOutput = AVCapturePhotoOutput()

func capturePhoto(completion: @escaping (Data) -> Void) {
    let settings = AVCapturePhotoSettings()
    
    // Capture in highest quality
    settings.isHighResolutionPhotoEnabled = true
    
    // Request RAW + JPEG if you want maximum processing flexibility
    // For v1, JPEG/HEIF is fine
    if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
        settings.photoQualityPrioritization = .quality
    }
    
    // Flash
    settings.flashMode = flashEnabled ? .on : .off
    
    photoOutput.capturePhoto(with: settings, delegate: self)
}

// In AVCapturePhotoCaptureDelegate:
func photoOutput(_ output: AVCapturePhotoOutput,
                 didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard let imageData = photo.fileDataRepresentation() else { return }
    
    // Save raw capture to app sandbox
    // Queue it for "developing" (processing pipeline)
    DevelopmentQueue.shared.enqueue(imageData, metadata: captureMetadata)
}
```

**Capture metadata to save alongside each photo:**
- Which lens was used (for per-lens filter tuning)
- Focus point
- Exposure values
- Timestamp
- Location (if enabled)
- Selected film stock preset

### Video Capture

Video is your third priority but it's important to architect for it from the start.

```swift
private let movieOutput = AVCaptureMovieFileOutput()

func startRecording() {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
    
    movieOutput.startRecording(to: outputURL, recordingDelegate: self)
}

func stopRecording() {
    movieOutput.stopRecording()
}

// Post-capture: Apply film filter to video using AVAssetExportSession + CIFilter
func processVideo(at url: URL, withFilmStock stock: FilmStock) async -> URL {
    let asset = AVURLAsset(url: url)
    let composition = AVVideoComposition(asset: asset) { request in
        // This closure is called per-frame
        let source = request.sourceImage.clampedToExtent()
        
        // Apply your film processing pipeline to each frame
        let processed = FilmProcessor.shared.process(
            source,
            filmStock: stock,
            addLightLeaks: false  // Light leaks on video = once per clip, not per frame
        )
        
        request.finish(with: processed, context: nil)
    }
    
    // Export
    let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
    export.videoComposition = composition
    export.outputURL = outputURL
    export.outputFileType = .mov
    await export.export()
    
    return outputURL
}
```

**Video-specific considerations:**
- Film filter must run at 30fps per-frame — keep the CIFilter chain lean
- Light leaks on video: apply as a single overlay for the duration of the clip (not randomized per frame, that would look like flickering). Maybe 1-2 static leaks that fade in/out
- Grain on video: use a looping grain texture (not random per-frame, that looks digital). Real film grain has temporal coherence — the same grain pattern persists for a single frame then shifts
- Audio: record audio alongside, no processing needed (or add subtle film projector noise as an option?)
- Video "developing" could take longer — show a progress bar styled as a film processing machine

---

## Module 2: Processing Pipeline (Core Image + Metal)

This is where the art happens. Each "film stock" is a configuration of the filter chain.

### Film Stock Data Model

```swift
struct FilmStock: Codable, Identifiable {
    let id: String
    let name: String              // "Superia 400", "Portra 800", "Ektar 100"
    let era: String               // "1998", "2004", "1970s"
    
    // Color grading
    let lutFileName: String       // "superia400.png" — 3D LUT as a 2D texture
    let warmthShift: Float        // -1.0 (cool) to 1.0 (warm)
    let contrastBoost: Float      // 0.0 to 0.5
    let saturationMultiplier: Float // 0.8 to 1.3
    
    // Grain
    let grainIntensity: Float     // 0.0 to 0.4
    let grainSize: Float          // 1.0 (fine) to 3.0 (coarse) — higher ISO = coarser
    
    // Light leaks
    let lightLeakProbability: Float  // 0.0 to 1.0 (how often leaks appear)
    let lightLeakIntensity: Float    // 0.3 to 1.0
    let lightLeakPalette: [String]   // ["warm", "cool", "red"] — which overlay set to draw from
    
    // Chromatic aberration
    let chromaticAberrationAmount: Float // 0.0 to 5.0 pixels
    
    // Vignette
    let vignetteIntensity: Float  // 0.0 to 2.0
    let vignetteRadius: Float     // 0.5 to 3.0
    
    // Date stamp
    let dateStampStyle: DateStampStyle  // .lcd, .dot_matrix, .handwritten, .none
    let defaultYear: Int?         // nil = current year, or 1998, 2004, etc.
}

// Example presets
extension FilmStock {
    static let superia400 = FilmStock(
        id: "superia400",
        name: "Superia 400",
        era: "1998",
        lutFileName: "superia400_lut",
        warmthShift: 0.3,
        contrastBoost: 0.15,
        saturationMultiplier: 1.1,
        grainIntensity: 0.2,
        grainSize: 1.5,
        lightLeakProbability: 0.6,
        lightLeakIntensity: 0.7,
        lightLeakPalette: ["warm"],
        chromaticAberrationAmount: 2.0,
        vignetteIntensity: 0.8,
        vignetteRadius: 2.0,
        dateStampStyle: .lcd,
        defaultYear: 1998
    )
    
    static let portra800 = FilmStock(
        id: "portra800",
        name: "Portra 800",
        era: "2004",
        lutFileName: "portra800_lut",
        warmthShift: 0.15,
        contrastBoost: 0.05,
        saturationMultiplier: 0.95,
        grainIntensity: 0.25,
        grainSize: 2.0,
        lightLeakProbability: 0.3,
        lightLeakIntensity: 0.5,
        lightLeakPalette: ["warm", "cool"],
        chromaticAberrationAmount: 1.0,
        vignetteIntensity: 0.5,
        vignetteRadius: 2.5,
        dateStampStyle: .lcd,
        defaultYear: nil
    )
}
```

### The Main Processing Pipeline

```swift
class FilmProcessor {
    static let shared = FilmProcessor()
    
    // Reuse the CIContext — expensive to create
    private let context = CIContext(options: [
        .useSoftwareRenderer: false,  // Force GPU
        .highQualityDownsample: true
    ])
    
    // Cache loaded LUTs
    private var lutCache: [String: CIImage] = [:]
    
    // Cache loaded light leak overlays
    private var lightLeakCache: [String: [CIImage]] = [:]
    
    func process(_ inputImage: CIImage, filmStock: FilmStock) -> CIImage {
        var image = inputImage
        
        // Step 1: Color LUT
        image = applyLUT(image, lutName: filmStock.lutFileName)
        
        // Step 2: Color adjustments (fine-tune on top of LUT)
        image = applyColorAdjustments(image, stock: filmStock)
        
        // Step 3: Film grain
        image = applyGrain(image, 
                          intensity: filmStock.grainIntensity, 
                          size: filmStock.grainSize)
        
        // Step 4: Light leaks (random)
        if Float.random(in: 0...1) < filmStock.lightLeakProbability {
            image = applyLightLeaks(image, stock: filmStock)
        }
        
        // Step 5: Chromatic aberration
        if filmStock.chromaticAberrationAmount > 0 {
            image = applyChromaticAberration(image, 
                                            amount: filmStock.chromaticAberrationAmount)
        }
        
        // Step 6: Vignette
        image = image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: filmStock.vignetteIntensity,
            kCIInputRadiusKey: filmStock.vignetteRadius
        ])
        
        // Step 7: Date stamp
        if filmStock.dateStampStyle != .none {
            image = applyDateStamp(image, style: filmStock.dateStampStyle,
                                   year: filmStock.defaultYear)
        }
        
        return image
    }
    
    // Render final output
    func render(_ processedImage: CIImage) -> Data? {
        guard let cgImage = context.createCGImage(processedImage, 
                                                   from: processedImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.95)
    }
}
```

### Color LUT Application

A LUT (Look-Up Table) is the professional way to do color grading. You design your film look in Lightroom/Capture One, export as a .cube file, convert to a texture, and apply it with `CIColorCubeWithColorSpace`.

```swift
func applyLUT(_ image: CIImage, lutName: String) -> CIImage {
    // Load LUT data (cache this)
    if lutCache[lutName] == nil {
        // Load your .cube LUT file and convert to float array
        // This is a one-time operation per LUT
        lutCache[lutName] = loadLUTData(named: lutName)
    }
    
    guard let lutData = lutCache[lutName] else { return image }
    
    let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(64, forKey: "inputCubeDimension")  // 64x64x64 LUT
    filter.setValue(lutData, forKey: "inputCubeData")
    filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
    
    return filter.outputImage ?? image
}
```

**How to create your LUTs:**
1. Take 20-30 diverse reference photos (skin tones, landscapes, night scenes, food, etc.)
2. In Lightroom: edit them to match your target film look (study real film scans for reference)
3. Export as a .cube LUT using a Lightroom plugin or Photoshop
4. Convert .cube to the float array format Core Image expects
5. Test extensively — LUTs can clip highlights/shadows badly on edge-case images

### Film Grain (Custom Metal Kernel)

```metal
// GrainKernel.metal
#include <CoreImage/CoreImage.h>

extern "C" {
    float4 grainKernel(coreimage::sample_t pixel,
                       float intensity,
                       float time,       // Use frame time for variation
                       coreimage::destination dest) {
        
        // Generate pseudo-random noise based on pixel position
        float2 pos = dest.coord();
        float noise = fract(sin(dot(pos, float2(12.9898, 78.233)) + time) * 43758.5453);
        
        // Bias toward midtones (real film grain is less visible in pure black/white)
        float luminance = dot(pixel.rgb, float3(0.299, 0.587, 0.114));
        float grainMask = 1.0 - abs(luminance - 0.5) * 2.0;  // Peak at mid-gray
        grainMask = mix(0.3, 1.0, grainMask);  // Don't completely eliminate in shadows/highlights
        
        // Apply grain
        float grainAmount = (noise - 0.5) * intensity * grainMask;
        float3 result = pixel.rgb + grainAmount;
        
        return float4(result, pixel.a);
    }
}
```

```swift
// Swift wrapper
class GrainFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputIntensity: Float = 0.2
    
    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }
        
        return Self.kernel.apply(
            extent: input.extent,
            arguments: [input, inputIntensity, Float.random(in: 0...1000)]
        )
    }
    
    static private var kernel: CIColorKernel = {
        let url = Bundle.main.url(forResource: "default", withExtension: "metallib")!
        let data = try! Data(contentsOf: url)
        return try! CIColorKernel(functionName: "grainKernel", fromMetalLibraryData: data)
    }()
}
```

### Light Leak Compositor

```swift
func applyLightLeaks(_ image: CIImage, stock: FilmStock) -> CIImage {
    var result = image
    let count = Int.random(in: 1...3)
    
    for _ in 0..<count {
        // Pick random overlay from the palette
        let paletteName = stock.lightLeakPalette.randomElement()!
        let overlays = loadLightLeakOverlays(palette: paletteName)
        guard let overlay = overlays.randomElement() else { continue }
        
        // Randomize transform
        let imageSize = image.extent.size
        var leak = overlay
        
        // Random scale (50% to 150% of image size)
        let scale = CGFloat.random(in: 0.5...1.5)
        leak = leak.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Random rotation
        let angle = CGFloat.random(in: 0...(2 * .pi))
        leak = leak.transformed(by: CGAffineTransform(rotationAngle: angle))
        
        // Random position
        let tx = CGFloat.random(in: -imageSize.width * 0.3...imageSize.width * 0.7)
        let ty = CGFloat.random(in: -imageSize.height * 0.3...imageSize.height * 0.7)
        leak = leak.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        
        // Crop to image bounds
        leak = leak.cropped(to: image.extent)
        
        // Random opacity
        let opacity = Float.random(in: 0.3...stock.lightLeakIntensity)
        leak = leak.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
        
        // Blend using Screen mode (brightens, never darkens)
        result = leak.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: result
        ])
    }
    
    return result
}
```

### Chromatic Aberration (Custom Metal Warp Kernel)

```metal
// ChromaticAberration.metal
#include <CoreImage/CoreImage.h>

extern "C" {
    float2 chromaticAberrationWarp(float amount,
                                    float2 imageSize,
                                    coreimage::destination dest) {
        float2 center = imageSize / 2.0;
        float2 pos = dest.coord();
        float2 dir = pos - center;
        float dist = length(dir / imageSize);  // Normalize by image size
        
        // Aberration increases toward edges (quadratic falloff)
        float aberration = dist * dist * amount;
        
        return pos + normalize(dir) * aberration;
    }
}
```

For chromatic aberration you actually need to process R, G, B channels separately with different warp amounts. This requires splitting the image, applying different warps, and recombining — or writing a general `CIKernel` that samples three offset positions.

### Date Stamp

```swift
func applyDateStamp(_ image: CIImage, style: DateStampStyle, year: Int?) -> CIImage {
    let imageSize = image.extent.size
    
    // Create the date string
    let date = Date()
    let calendar = Calendar.current
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let displayYear = year ?? calendar.component(.year, from: date)
    let shortYear = displayYear % 100
    let dateString = String(format: "%02d.%02d.%02d", shortYear, month, day)
    
    // Render text to CGImage
    let renderer = UIGraphicsImageRenderer(size: imageSize)
    let stampImage = renderer.image { ctx in
        // Transparent background
        ctx.cgContext.clear(CGRect(origin: .zero, size: imageSize))
        
        // Configure text
        let font: UIFont
        switch style {
        case .lcd:
            font = UIFont(name: "Your-LCD-Font", size: imageSize.height * 0.04) 
                   ?? UIFont.monospacedSystemFont(ofSize: imageSize.height * 0.04, weight: .regular)
        case .dotMatrix:
            font = UIFont(name: "Your-DotMatrix-Font", size: imageSize.height * 0.035)
                   ?? UIFont.monospacedSystemFont(ofSize: imageSize.height * 0.035, weight: .light)
        default:
            font = UIFont.monospacedSystemFont(ofSize: imageSize.height * 0.04, weight: .regular)
        }
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 0.85) // Warm amber
        ]
        
        let textSize = dateString.size(withAttributes: attributes)
        let margin = imageSize.width * 0.03
        let origin = CGPoint(
            x: imageSize.width - textSize.width - margin,
            y: imageSize.height - textSize.height - margin
        )
        
        dateString.draw(at: origin, withAttributes: attributes)
    }
    
    // Convert to CIImage and composite
    guard let cgStamp = stampImage.cgImage else { return image }
    let ciStamp = CIImage(cgImage: cgStamp)
    
    return ciStamp.composited(over: image)
}
```

---

## Module 3: "The Lab" — Development Queue & Gallery

### Development Queue

This manages the async processing of captured photos, mimicking the "developing" experience.

```swift
@Observable
class DevelopmentQueue {
    static let shared = DevelopmentQueue()
    
    struct PendingPhoto: Identifiable {
        let id = UUID()
        let rawImageData: Data
        let captureMetadata: CaptureMetadata
        let filmStock: FilmStock
        let capturedAt: Date
        var status: DevelopmentStatus = .developing
    }
    
    enum DevelopmentStatus {
        case developing(progress: Float)
        case ready(processedImagePath: String)
        case failed(Error)
    }
    
    @Published var pending: [PendingPhoto] = []
    @Published var developed: [DevelopedPhoto] = []
    
    private let processingQueue = DispatchQueue(label: "dev.yourapp.processing", 
                                                 qos: .userInitiated,
                                                 attributes: .concurrent)
    
    func enqueue(_ imageData: Data, metadata: CaptureMetadata, filmStock: FilmStock) {
        let photo = PendingPhoto(rawImageData: imageData, 
                                  captureMetadata: metadata, 
                                  filmStock: filmStock,
                                  capturedAt: Date())
        pending.append(photo)
        
        processingQueue.async { [weak self] in
            self?.develop(photo)
        }
    }
    
    private func develop(_ photo: PendingPhoto) {
        guard let ciImage = CIImage(data: photo.rawImageData) else { return }
        
        // Process through the film pipeline
        let processed = FilmProcessor.shared.process(ciImage, filmStock: photo.filmStock)
        
        // Render to JPEG
        guard let outputData = FilmProcessor.shared.render(processed) else { return }
        
        // Save to app sandbox
        let filename = "\(photo.id.uuidString).jpg"
        let path = getDocumentsDirectory().appendingPathComponent("developed/\(filename)")
        try? outputData.write(to: path)
        
        // Update status
        DispatchQueue.main.async {
            // Move from pending to developed
            // Trigger UI update
        }
    }
}
```

### Photo Storage Structure

```
App Sandbox/
├── raw/                    # Original unprocessed captures
│   ├── {uuid}.heic
│   └── {uuid}.json        # Metadata (lens, focus point, film stock, etc.)
├── developed/              # Processed photos
│   ├── {uuid}.jpg
│   └── {uuid}_thumb.jpg   # Thumbnail for gallery
├── rolls/                  # Grouping mechanism
│   └── {roll_id}.json     # List of photo IDs in this roll
└── light_leaks/            # Bundled overlay textures
    ├── warm/
    ├── cool/
    └── red/
```

---

## Module 4: UI Architecture (SwiftUI)

### App Structure

```swift
@main
struct FilmCameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var currentTab: AppTab = .camera
    
    var body: some View {
        ZStack {
            switch currentTab {
            case .camera:
                CameraView(onOpenLab: { currentTab = .lab })
            case .lab:
                LabView(onOpenCamera: { currentTab = .camera })
            case .filmPicker:
                FilmPickerView()
            }
        }
    }
}
```

### Camera View Layout

```
┌──────────────────────────────────┐
│  [0.5x] [1x] [2x]    [⚡ flash] │  ← Lens picker + flash toggle
│                                  │
│                                  │
│         Camera Preview           │
│      (AVCaptureVideoPreview)     │
│                                  │
│         ○  ← focus ring          │
│           (on tap)               │
│                                  │
│                                  │
├──────────────────────────────────┤
│                                  │
│  [Film: Superia 400]             │  ← Current film stock
│                                  │
│  [Lab 📷3]    [ ◉ ]    [⟳ flip] │  ← Lab (w/ pending count), Shutter, Flip camera
│                                  │
│  ●────────○ Photo    Video       │  ← Mode toggle (phase 2)
│                                  │
└──────────────────────────────────┘
```

---

## Module 5: Development Phases

### Phase 1 — Core Camera + Single Film Stock (4-6 weeks)
- [ ] AVFoundation camera session setup
- [ ] Multi-lens discovery and switching (0.5x / 1x / 2x buttons)
- [ ] Tap-to-focus with visual indicator
- [ ] Photo capture to app sandbox
- [ ] Basic film processing pipeline (one hardcoded "Superia 400" preset)
  - [ ] Color grading (start with CIFilter chain, upgrade to LUT later)
  - [ ] Film grain (start with noise overlay, upgrade to Metal kernel later)
  - [ ] Light leak compositing (start with 10-15 hand-made overlays)
  - [ ] Vignette
  - [ ] Date stamp
- [ ] "The Lab" gallery with developing animation
- [ ] Save to camera roll via Photos framework
- [ ] Basic SwiftUI app shell

### Phase 2 — Multiple Film Stocks + Polish (3-4 weeks)
- [ ] FilmStock data model and preset system
- [ ] 4-6 film stock presets with unique LUTs
- [ ] Film picker UI (scrollable strip or carousel)
- [ ] Custom Metal kernels (grain, chromatic aberration)
- [ ] More light leak overlays (30-50 total across palettes)
- [ ] "Roll" concept — group photos by session/day
- [ ] Haptic feedback on shutter press
- [ ] Shutter sound (optional, film-camera style)
- [ ] Share sheet integration
- [ ] Selfie camera support

### Phase 3 — Video Mode (3-4 weeks)
- [ ] AVCaptureMovieFileOutput integration
- [ ] Per-frame film processing via AVVideoComposition
- [ ] Optimize pipeline for 30fps
- [ ] Temporal grain (looping grain texture, not random per-frame)
- [ ] Static light leaks for video (fade in/out)
- [ ] Video export with processing progress UI
- [ ] Photo/Video mode toggle in UI

### Phase 4 — Social & Cloud (future)
- [ ] User accounts
- [ ] Cloud backup (CloudKit or custom backend)
- [ ] Shared rolls
- [ ] Export presets / share film stocks

---

## Xcode Project Setup

### Build Settings
- Deployment target: iOS 17.0+ (for latest AVFoundation and SwiftUI features)
- Metal Linker Build Options: `-framework CoreImage` (for custom CIKernels)

### Key Frameworks
- `AVFoundation` — camera capture
- `CoreImage` — image processing pipeline
- `Metal` — custom GPU kernels
- `Photos` — camera roll export
- `SwiftUI` — UI
- `SwiftData` — local persistence (metadata, rolls, settings)

### Bundle Resources
- Light leak overlay PNGs (in asset catalog or bundle)
- LUT files (.cube converted to binary)
- Custom fonts for date stamp (LCD/dot-matrix .ttf files)
- Shutter/film advance sound effects (.caf files)

### Privacy Keys (Info.plist)
```xml
<key>NSCameraUsageDescription</key>
<string>Take photos and videos with film effects</string>
<key>NSMicrophoneUsageDescription</key>
<string>Record audio with your videos</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Save developed photos to your camera roll</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Tag your photos with location (optional)</string>
```

---

## Performance Considerations

- **CIContext**: Create ONCE, reuse everywhere. Creating a CIContext is expensive (~50ms)
- **Filter chain**: Core Image lazily evaluates — the entire chain compiles to a single GPU pass. Don't force intermediate renders
- **LUT loading**: Load and cache LUT data on first use, not at app launch
- **Light leak overlays**: Load into memory lazily, cache the most recent ones
- **Thumbnail generation**: Generate thumbnails at save time (e.g., 300px wide) for fast gallery scrolling
- **Background processing**: Use `DispatchQueue` with `.userInitiated` QoS for photo processing, `.utility` for thumbnails
- **Video processing**: This is the bottleneck — test on oldest supported device (iPhone 12 if targeting iOS 17)
- **Memory**: High-res photos can be 12-48MP. Use `CIImage` throughout the pipeline (lazy) and only render to `CGImage` at the final output step
