import SwiftUI
import UIKit

/// Geometry for framing a cover photo, kept free of SwiftUI so it can be unit
/// tested (`CoverCropTests`). Sizes are in the image's own points (`UIImage.size`,
/// orientation already applied); `offset` is how far the image's centre has been
/// dragged from the frame's centre, in screen points.
enum CoverCrop {
    /// Pinching can go this far past "just fills the frame".
    static let maxZoom: CGFloat = 4
    /// What a cover is rendered to on Done, 3 : 2, matching `CoverPhotoView`.
    static let outputSize = CGSize(width: 1500, height: 1000)

    /// The smallest scale at which the image still covers the whole frame
    /// (aspect fill). A vertical or small photo therefore starts zoomed in to
    /// fill the frame, and zooming out can never reveal empty bars.
    static func minScale(image: CGSize, frame: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(frame.width / image.width, frame.height / image.height)
    }

    /// Keeps the image covering the frame: the centre may move only as far as
    /// the scaled image overhangs the frame on each axis.
    static func clampedOffset(_ offset: CGSize, scale: CGFloat, image: CGSize, frame: CGSize) -> CGSize {
        let maxX = max(0, (image.width * scale - frame.width) / 2)
        let maxY = max(0, (image.height * scale - frame.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    /// The part of the image inside the frame, in image points.
    static func cropRect(scale: CGFloat, offset: CGSize, image: CGSize, frame: CGSize) -> CGRect {
        let o = clampedOffset(offset, scale: scale, image: image, frame: frame)
        // Frame's top-left measured from the scaled image's top-left; dragging the
        // image right (+x) brings more of its left side into the frame.
        let x = (image.width * scale - frame.width) / 2 - o.width
        let y = (image.height * scale - frame.height) / 2 - o.height
        let rect = CGRect(x: x / scale, y: y / scale, width: frame.width / scale, height: frame.height / scale)
        // Only floating-point slivers can fall outside after clamping.
        return rect.intersection(CGRect(origin: .zero, size: image))
    }

    /// Draws just `crop` of `image` into a fresh `outputSize` bitmap. What gets
    /// uploaded, so every screen shows exactly what was framed.
    static func render(_ image: UIImage, crop: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            let s = outputSize.width / crop.width
            image.draw(in: CGRect(x: -crop.minX * s, y: -crop.minY * s,
                                  width: image.size.width * s, height: image.size.height * s))
        }
    }
}

/// Full-screen cover framing: the photo behind a fixed frame shaped exactly like
/// the profile's cover. Drag to reposition, pinch to zoom; the part outside the
/// frame stays visible but dimmed so it's clear what will be cut off.
struct CoverCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager

    /// 1 = just fills the frame; up to `CoverCrop.maxZoom`.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    private let margin: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = frameSize(in: geo.size)
                let scale = effectiveScale(frame: frame)
                let shown = CoverCrop.clampedOffset(
                    CGSize(width: offset.width + dragDelta.width, height: offset.height + dragDelta.height),
                    scale: scale, image: image.size, frame: frame)
                let interacting = dragDelta != .zero || pinch != 1

                ZStack {
                    // Whole photo, dimmed. What falls outside the frame.
                    photo(scale: scale, offset: shown)
                        .opacity(0.35)

                    // The same photo at full brightness, inside the frame only.
                    photo(scale: scale, offset: shown)
                        .mask(Rectangle().frame(width: frame.width, height: frame.height))

                    // The top of the cover sits under the status bar and fades on
                    // the profile, hinted here so nothing important gets framed there.
                    LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: frame.width, height: frame.height * CoverPhotoView.fadedTopFraction)
                        .frame(width: frame.width, height: frame.height, alignment: .top)
                        .allowsHitTesting(false)
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                    if interacting {
                        thirdsGrid
                            .frame(width: frame.width, height: frame.height)
                            .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                // Zoomed in, the dimmed overflow would otherwise spill up behind
                // the (glass, see-through) navigation bar and status bar.
                .clipped()
                .contentShape(Rectangle())
                .gesture(SimultaneousGesture(dragGesture(scale: scale, frame: frame),
                                             pinchGesture(frame: frame)))
                .animation(.easeOut(duration: 0.15), value: interacting)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(bundle.loc("Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            let crop = CoverCrop.cropRect(scale: scale, offset: offset, image: image.size, frame: frame)
                            onDone(CoverCrop.render(image, crop: crop))
                            dismiss()
                        } label: {
                            Text("Done", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle(bundle.loc("Adjust cover"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: - Pieces

    private func photo(scale: CGFloat, offset: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: image.size.width * scale, height: image.size.height * scale)
            .offset(offset)
            .accessibilityHidden(true)
    }

    /// Rule-of-thirds guides, shown only while dragging or pinching.
    private var thirdsGrid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Text("Drag to reposition · Pinch to zoom", bundle: bundle)
                .scaledFont(13)
                .foregroundColor(.white.opacity(0.7))
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    zoom = 1
                    offset = .zero
                }
            } label: {
                Text("Reset", bundle: bundle)
                    .scaledFont(15, .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .disabled(zoom == 1 && offset == .zero)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    // MARK: - Geometry + gestures

    private func frameSize(in container: CGSize) -> CGSize {
        let width = max(1, container.width - margin * 2)
        return CGSize(width: width, height: width / CoverPhotoView.aspectRatio)
    }

    private func effectiveScale(frame: CGSize) -> CGFloat {
        let liveZoom = min(max(zoom * pinch, 1), CoverCrop.maxZoom)
        return CoverCrop.minScale(image: image.size, frame: frame) * liveZoom
    }

    private func dragGesture(scale: CGFloat, frame: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                let moved = CGSize(width: offset.width + value.translation.width,
                                   height: offset.height + value.translation.height)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offset = CoverCrop.clampedOffset(moved, scale: scale, image: image.size, frame: frame)
                }
            }
    }

    private func pinchGesture(frame: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    zoom = min(max(zoom * value.magnification, 1), CoverCrop.maxZoom)
                    // Zooming out shrinks the overhang. Pull the photo back to cover the frame.
                    let scale = CoverCrop.minScale(image: image.size, frame: frame) * zoom
                    offset = CoverCrop.clampedOffset(offset, scale: scale, image: image.size, frame: frame)
                }
            }
    }
}
