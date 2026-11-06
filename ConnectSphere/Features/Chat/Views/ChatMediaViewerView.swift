import SwiftUI
import AVKit

/// A single media item opened in the fullscreen viewer (from a chat bubble or the gallery).
struct ChatMediaViewerItem: Identifiable {
    let id: String
    let url: URL
    let isVideo: Bool
}

/// View a chat's images/videos fullscreen: horizontal pager when there are multiple media items,
/// images support pinch-zoom + double-tap, videos play via AVPlayer. Swipe down
/// (while not zoomed in) to close: the media follows the finger and the
/// backdrop fades, showing the screen behind.
struct ChatMediaViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let items: [ChatMediaViewerItem]
    @State private var currentIndex: Int
    @State private var saver = MediaSaveViewModel()
    /// A zoomed-in photo pans instead; swipe-down only works at normal size.
    @State private var isZoomed = false
    /// How far the media has been pulled down.
    @State private var pull: CGFloat = 0

    /// 0 at rest, 1 at the point where letting go closes the viewer.
    private var pullProgress: CGFloat { min(max(pull / Self.closeDistance, 0), 1) }
    private static let closeDistance: CGFloat = 120

    init(items: [ChatMediaViewerItem], startIndex: Int = 0) {
        self.items = items
        _currentIndex = State(initialValue: min(max(0, startIndex), max(0, items.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - pullProgress * 0.75).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        if item.isVideo {
                            VideoPlayerPage(url: item.url, isActive: currentIndex == index)
                        } else {
                            ZoomableAsyncImage(url: item.url, isZoomed: $isZoomed)
                        }
                    }
                    .tag(index)
                    .contextMenu {
                        Button {
                            save(item)
                        } label: {
                            Label(Bundle.app.loc("Save to Photos"), systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: pull)
            .scaleEffect(reduceMotion ? 1 : 1 - pullProgress * 0.12)
            .gesture(SwipeDownPan(isEnabled: !isZoomed, onChange: { pull = max(0, $0) }, onEnd: endPull))

            // Overlay: close button + page counter
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .scaledFont(16, .semibold)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .accessibilityLabel(Bundle.app.loc("Close"))
                    Spacer()
                    if items.indices.contains(currentIndex) {
                        Button { save(items[currentIndex]) } label: {
                            Image(systemName: "arrow.down.to.line")
                                .scaledFont(16, .semibold)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .disabled(saver.isSaving)
                        .accessibilityLabel(Text(Bundle.app.loc("Save to Photos")))
                    }
                    if items.count > 1 {
                        Text("\(currentIndex + 1)/\(items.count)")
                            .scaledFont(14, .semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            .opacity(1 - pullProgress)
        }
        // See-through while pulled, so the screen behind shows as it fades.
        .presentationBackground(.clear)
        .mediaSaveStatus(saver)
        .statusBarHidden()
    }

    /// Far enough, or a quick flick, closes; otherwise it springs back.
    private func endPull(translation: CGFloat, velocity: CGFloat) {
        if translation > Self.closeDistance || (translation > 30 && velocity > 900) {
            dismiss()
        } else {
            withAnimation(.spring(duration: 0.3)) { pull = 0 }
        }
    }

    private func save(_ item: ChatMediaViewerItem) {
        Task { await saver.save([.init(url: item.url, isVideo: item.isVideo)]) }
    }
}

// MARK: - Video page

/// Video page: auto-plays when it's the current page, pauses when swiping to another page.
private struct VideoPlayerPage: View {
    let url: URL
    let isActive: Bool

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                if player == nil { player = AVPlayer(url: url) }
                if isActive { player?.play() }
            }
            .onChange(of: isActive) { _, active in
                if active { player?.play() } else { player?.pause() }
            }
            .onDisappear { player?.pause() }
    }
}

// MARK: - Zoomable image page

/// Fullscreen image: pinch to zoom (1x-4x), double-tap to toggle 2.5x,
/// drag to pan while zoomed. Resets when leaving the page.
private struct ZoomableAsyncImage: View {
    let url: URL
    /// Tells the viewer when the photo is zoomed in (so swipe-down stays off).
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoomGesture)
                        // Only while zoomed: an always-on drag claimed every
                        // horizontal swipe, so the pager couldn't leave a photo.
                        .simultaneousGesture(panGesture, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) { toggleZoom() }
                case .failure:
                    failurePlaceholder
                        .frame(width: geo.size.width, height: geo.size.height)
                default:
                    ProgressView()
                        .tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .onDisappear { resetZoom() }
        .onChange(of: scale) { _, value in isZoomed = value > 1 }
    }

    private var failurePlaceholder: some View {
        Image(systemName: "photo")
            .scaledFont(40)
            .foregroundColor(.white.opacity(0.6))
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

// MARK: - Swipe down to close

/// A pan that only starts on a mostly-downward swipe, so sideways swipes
/// still page between items and the video scrubber still works. A SwiftUI
/// drag on the pager would claim every swipe (the pager couldn't page).
private struct SwipeDownPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let y = recognizer.translation(in: recognizer.view).y
        switch recognizer.state {
        case .changed: onChange(y)
        case .ended, .cancelled, .failed: onEnd(y, recognizer.velocity(in: recognizer.view).y)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return v.y > 0 && v.y > abs(v.x) * 1.5
        }
    }
}
