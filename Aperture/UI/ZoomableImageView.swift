import SwiftUI

struct ZoomableImageView: View {
  let image: UIImage
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var scale: CGFloat = 1
  @State private var baseScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var baseOffset: CGSize = .zero

  var body: some View {
    GeometryReader { proxy in
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .scaleEffect(scale)
        .offset(offset)
        .frame(width: proxy.size.width, height: proxy.size.height)
        .contentShape(Rectangle())
        .gesture(magnificationGesture)
        .simultaneousGesture(dragGesture(in: proxy.size))
        .onTapGesture(count: 2) {
          withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
            if scale > 1 {
              reset()
            } else {
              scale = 2
              baseScale = 2
            }
          }
        }
        .accessibilityLabel("Photo")
        .accessibilityValue(scale > 1 ? "Zoomed in" : "Fit to screen")
        .accessibilityHint("Pinch or double tap to zoom")
    }
  }

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in
        scale = min(max(baseScale * value, 1), 6)
        if scale == 1 { offset = .zero }
      }
      .onEnded { _ in
        baseScale = scale
        if scale == 1 { reset() }
      }
  }

  private func dragGesture(in size: CGSize) -> some Gesture {
    DragGesture()
      .onChanged { value in
        guard scale > 1 else { return }
        let proposed = CGSize(
          width: baseOffset.width + value.translation.width,
          height: baseOffset.height + value.translation.height
        )
        offset = clamped(proposed, in: size)
      }
      .onEnded { _ in
        baseOffset = offset
      }
  }

  private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
    let horizontal = size.width * (scale - 1) / 2
    let vertical = size.height * (scale - 1) / 2
    return CGSize(
      width: min(max(proposed.width, -horizontal), horizontal),
      height: min(max(proposed.height, -vertical), vertical)
    )
  }

  private func reset() {
    scale = 1
    baseScale = 1
    offset = .zero
    baseOffset = .zero
  }
}
