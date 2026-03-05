# Huji Cam: Research & Build Guide

## What Huji Actually Is

Huji Cam is a camera app by **Manhole, Inc.** (a South Korean indie studio based in Yeosu, South Korea). It launched in late 2017 and went viral in mid-2018 after Selena Gomez and Kim Kardashian started posting Huji photos on Instagram. It has over **45 million downloads** across iOS and Android. The app is small (~13-30MB), free with a ~$0.99 IAP for auto-save and gallery import.

The core idea: replicate the **experience and aesthetic of a 1998 disposable film camera** — not just a filter, but the whole ritual of shooting, waiting, and discovering.

---

## Feature Breakdown

### Camera Experience
- **Viewfinder UI**: Mimics looking through a real disposable camera viewfinder — tiny by default, tap/hold to go full-screen (landscape mode encouraged)
- **Shutter button**: Simple, one-tap capture — no focus, no exposure controls, no zoom
- **Flash toggle**: On/off, simulates disposable camera flash (harsh, direct)
- **Selfie camera**: Front-facing supported
- **Timer**: Countdown shutter
- **No manual controls**: Intentionally no focus ring, no exposure, no white balance — the "limitation is the feature"

### Processing / "Developing"
- **Simulated development time**: After capture, a film-roll animation plays while the photo "develops" — takes a few seconds
- **Development only happens while app is in foreground** — mimics real waiting
- **Photos land in "The Lab"** — an in-app gallery styled like a photo lab, not a camera roll

### The Filter / Look
- **Warm color shift**: Pushes colors toward warm tones (yellows, oranges) — mimics cheap consumer film (think Fujifilm Superia 400)
- **Increased contrast**: Blacks are crushed slightly, highlights bloom
- **Film grain**: Subtle noise overlay that varies per photo
- **Random light leaks**: The signature feature — semi-transparent warm/orange/yellow light bleed effects composited randomly onto photos. Position, size, opacity, and color vary per shot
- **Slight color fringing / chromatic aberration**: Mimics cheap plastic lens distortion
- **Soft vignette**: Subtle darkening at edges
- **Date stamp**: "98.01.15" style timestamp in bottom-right corner, configurable (1998, current year, or off), with a retro LCD-style font

### Key Settings
- Random light effects: On/off toggle
- Photo quality: Adjustable
- Date stamp: Format options, on/off
- Auto-save to camera roll (IAP)
- Preserve originals option
- Geo-tagging toggle
- Viewfinder touch mode

### Monetization
- Free app with ads
- Single IAP (~$0.99): Unlocks gallery import, auto-save, removes ads
- No subscription

---

## The Competitive Landscape

| App | Key Differentiator | Monetization |
|-----|-------------------|--------------|
| **Huji Cam** | Simplicity, random light leaks, the OG | Free + $0.99 IAP |
| **Gudak Cam** | Extreme authenticity: 24 shots/roll, 3-day wait to "develop" | $1.99 one-time |
| **Dazz Cam** | Multiple virtual camera models, video support, double exposure | Free + subscription |
| **CALLA Cam** | Mimics 35mm point-and-shoot, manual focus ring, multiple film stocks | Free + IAP per film |
| **KD Pro** | 3 film looks (Kodak/Fuji/B&W), adjustable dev time, film roll UI | Free + $0.99 premium |
| **Lapse** | Social layer — invite-only, friends see each other's developed photos, journals | Free (social/growth model) |
| **Dispo** | David Dobrik's app, social disposable — shoot now, photos develop next day at 9am | Free (VC-backed, social) |
| **FIMO** | Catalog of real film stock presets with authentic packaging UI | Free + IAP per film |
| **NOMO** | Mimics specific real cameras (Polaroid, Leica, etc.) with sound effects | Free + IAP per camera |

### Gaps and Opportunities
- **No strong social layer in Huji** — Lapse/Dispo tried this but retention was poor
- **No cloud backup** — users constantly lose photos; top complaint across all these apps
- **No shared albums / collaborative rolls** — group photo experiences are underserved
- **Limited customization** — most apps are either fully random or fully manual, no middle ground
- **No video** in Huji — Dazz Cam has it, but with weak film simulation
- **No cross-platform sync** — iOS/Android users in the same friend group can't share
- **AI-powered film simulation** is still unexplored — current apps use static overlays

---

## How Huji Is Built (Reverse-Engineered Architecture)

Huji is a native app — Swift/UIKit on iOS, Kotlin/Java on Android. There's no evidence of cross-platform frameworks. The app is lightweight and does all processing on-device.

### Architecture Overview

```
┌─────────────────────────────────────────────┐
│                   UI Layer                   │
│  Camera Viewfinder → Lab (Gallery) → Share   │
├─────────────────────────────────────────────┤
│              Camera Capture                  │
│  AVFoundation (iOS) / CameraX (Android)     │
├─────────────────────────────────────────────┤
│           Image Processing Pipeline          │
│  1. Color Grading (warm shift, contrast)     │
│  2. Grain Generation (noise texture)         │
│  3. Light Leak Compositing (blend overlays)  │
│  4. Chromatic Aberration (channel offset)    │
│  5. Vignette                                 │
│  6. Date Stamp Rendering                     │
├─────────────────────────────────────────────┤
│              Local Storage                   │
│  App sandbox → Photos framework (export)     │
└─────────────────────────────────────────────┘
```

### Image Processing Pipeline (The Core of It)

The "Huji look" is a chain of image processing steps applied sequentially. Here's what each step actually does technically:

#### 1. Color Grading / Film Emulation
- **What it does**: Shifts the color response to mimic Fujifilm Superia 400 or similar cheap consumer film
- **How to build it**:
  - iOS: Chain of `CIFilter`s — `CIColorControls` (contrast/saturation/brightness), `CITemperatureAndTint` (warm shift), `CIColorCurves` or `CIToneCurve` (custom S-curve for that film contrast)
  - Alternatively: A single Color LUT (Look-Up Table) — a 3D texture that remaps every input color to an output. This is how professional film emulation works (VSCO, RNI Films). You can export LUTs from Lightroom/Capture One and apply them with `CIColorCubeWithColorSpace`
  - Android: `RenderScript` or OpenGL ES shaders, or use GPUImage library

#### 2. Film Grain
- **What it does**: Adds per-pixel luminance noise that mimics silver halide grain
- **How to build it**:
  - Generate a noise texture (can be pre-baked or procedural via `CIRandomGenerator`)
  - Control grain size by scaling the noise
  - Blend using `CISourceOverCompositing` or a soft-light blend mode
  - Vary intensity — more visible in shadows and midtones, less in highlights (this is how real film grain behaves)
  - For advanced: Write a custom Metal `CIColorKernel` that adds noise based on luminance. Jacob Bartlett's CoreImageToy project has an open-source example of exactly this

#### 3. Light Leaks (The Signature Move)
- **What it does**: Composites semi-transparent warm-colored blobs onto the image, simulating light hitting the film through gaps in the camera body
- **How to build it**:
  - Pre-render a library of 20-50+ light leak overlay images (PNG with alpha) — warm gradients, streaks, blobs, flares in oranges/yellows/reds
  - On each capture, randomly select 0-3 overlays
  - Randomize: position (translate), scale, rotation, opacity
  - Blend mode: Screen or Additive — this makes them brighten the image rather than cover it
  - iOS: `CISourceOverCompositing`, `CIAdditionCompositing`, or `CIScreenBlendMode`
  - Key insight from FilterGrade analysis: Real light leaks are "in" the negative (they affect exposure), while Huji's are composited "on top." A more realistic approach would multiply the leak into the exposure before tone mapping, but Huji's approach is simpler and still looks great

#### 4. Chromatic Aberration
- **What it does**: Shifts the red, green, and blue color channels slightly apart, especially toward the edges — mimics cheap plastic lens
- **How to build it**:
  - Separate the image into R, G, B channels
  - Slightly scale/offset the R and B channels outward from center (G stays fixed)
  - Recombine — this creates colored fringing at high-contrast edges
  - iOS: Custom `CIWarpKernel` in Metal, or use `CICircularScreen` creatively
  - Amount should increase toward edges (radial function from center)

#### 5. Vignette
- **What it does**: Darkens the corners/edges of the frame
- **How to build it**:
  - iOS: Built-in `CIVignette` or `CIVignetteEffect` filter — set radius and intensity
  - Keep it subtle — Huji's vignette is gentle, not dramatic

#### 6. Date Stamp
- **What it does**: Renders a date in the bottom-right corner using a retro LCD/digital font
- **How to build it**:
  - Render text to a `CIImage` using Core Graphics / Core Text
  - Use a pixel font or dot-matrix style typeface (or the specific segmented LCD font Huji uses)
  - Composite onto the processed image at fixed position
  - Color: warm orange/amber, slightly transparent
  - Make the year configurable (1998 vs current)

---

## How To Build It: Tech Stack Recommendations

### Option A: Native iOS (Recommended for Best Quality)

**Language**: Swift
**UI**: SwiftUI (app chrome) + UIKit (camera preview via `AVCaptureVideoPreviewLayer`)
**Camera**: AVFoundation — `AVCaptureSession`, `AVCapturePhotoOutput`
**Image Processing**: Core Image (CIFilter chain) + Metal shaders for custom kernels
**Storage**: FileManager (app sandbox) + Photos framework (PHPhotoLibrary for export)
**Date Stamp Font**: Bundle a custom .ttf pixel font

**Pros**: Best performance, best camera access, best filter quality, smallest app size
**Cons**: iOS only

### Option B: Native Android

**Language**: Kotlin
**Camera**: CameraX (Jetpack)
**Image Processing**: RenderScript (deprecated but still works), or OpenGL ES / Vulkan compute shaders, or GPUImage library
**Storage**: MediaStore API

### Option C: Cross-Platform (React Native / Flutter)

**React Native**: `react-native-camera` or `expo-camera` + `gl-react` for GPU filters
**Flutter**: `camera` package + custom shader via `FragmentProgram` (Impeller renderer) or dart:ffi into native filter code

**Pros**: Ship to both platforms from one codebase
**Cons**: Camera access is more limited, filter performance is worse, harder to get the "feel" right. The viewfinder experience (the tactile, immediate feel) is notoriously hard to get right in cross-platform frameworks.

### Option D: The Hybrid Sweet Spot

Build the **camera capture + image processing pipeline natively** (Swift module for iOS, Kotlin module for Android), but use **cross-platform for the UI shell and social features** (React Native or Flutter). This is what Lapse and Dispo essentially did — native camera performance where it matters, shared UI/backend everywhere else.

---

## Building Your Version: Key Technical Decisions

### The Filter Pipeline Architecture

```swift
// Pseudocode: iOS Core Image filter chain
func processPhoto(_ input: CIImage) -> CIImage {
    var image = input
    
    // 1. Apply color LUT (film emulation)
    image = applyLUT(image, lut: "your_custom_film_lut")
    
    // 2. Adjust contrast + warmth
    image = image.applyingFilter("CIColorControls", parameters: [
        kCIInputContrastKey: 1.15,
        kCIInputSaturationKey: 1.1
    ])
    image = image.applyingFilter("CITemperatureAndTint", parameters: [
        "inputNeutral": CIVector(x: 5500, y: 0),  // warm shift
        "inputTargetNeutral": CIVector(x: 6500, y: 0)
    ])
    
    // 3. Add grain (custom Metal kernel or noise overlay)
    image = addFilmGrain(image, intensity: 0.15)
    
    // 4. Random light leaks
    if lightLeaksEnabled {
        image = compositeRandomLightLeaks(image, count: Int.random(in: 0...2))
    }
    
    // 5. Chromatic aberration
    image = applyChromaticAberration(image, amount: 2.0)
    
    // 6. Vignette
    image = image.applyingFilter("CIVignette", parameters: [
        kCIInputIntensityKey: 0.8,
        kCIInputRadiusKey: 2.0
    ])
    
    // 7. Date stamp
    image = compositeDate(image, date: Date(), style: .retro1998)
    
    return image
}
```

### Making Your Light Leak Library

You need a diverse set of overlay textures. Options:
1. **Create them in Photoshop/Procreate**: Paint soft radial gradients in warm colors on transparent backgrounds, varying size/shape/color
2. **Photograph real ones**: Shoot with a real disposable camera with the back cracked open slightly, scan the results, extract the leak patterns
3. **Procedural generation**: Use `CILinearGradient` + `CIGaussianBlur` + color transforms to generate them at runtime — more variety, zero storage cost
4. **Purchase overlay packs**: FilterGrade, Creative Market, etc. sell high-quality light leak texture packs

### The "Developing" Experience
- After capture, show a film canister / processing animation (Lottie is great for this)
- Apply the filter pipeline in the background
- Store raw capture + processed result
- The perceived delay (even if artificial) is part of the magic — it creates anticipation

---

## What Makes This Space Ripe for a New Entry

1. **Huji hasn't meaningfully updated in years** — the core product is frozen
2. **No social/sharing layer** exists in the original — this is the biggest unlock
3. **Cloud backup is the #1 user complaint** across every app in this category
4. **AI can now do film emulation better** than static filter chains — you could train a model on real film scans
5. **The "disposable" metaphor can evolve** — shared rolls, themed rolls, time-capsule rolls, etc.
6. **Video is underserved** — nobody does convincing film-look video yet
7. **Cross-platform is still unsolved** — friend groups split across iOS/Android can't share

---

## Resources

### Code & Libraries
- **CoreImageToy** (GitHub: jacobsapps/CoreImageToy) — Open-source iOS app with custom Metal CIFilter kernels including film grain
- **GPUImage** (GitHub) — Cross-platform GPU-accelerated image processing
- **Core Image Filter Reference** — Apple's complete list of 200+ built-in CIFilters
- **Metal Shading Language for Core Image Kernels** — Apple docs for writing custom GPU kernels

### Film Science
- FilterGrade's comparison of Huji vs. real film — explains the technical differences in how light leaks work digitally vs. on actual negatives
- RNI Films — study their approach to color science; they profile real film stocks

### Design Inspiration
- Study the viewfinder UX of Gudak, CALLA, and FIMO — each interprets "retro camera UI" differently
- Lapse's social model — journals, featured photos, instants (DMs)
- Dispo's "photos develop at 9am" mechanic — time-gated reveal as a social hook
