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
    /// Close, save, counter and the bottom bar, hidden by a single tap.
    @State private var chromeHidden = false
    /// One per video, shared by its page (gestures) and the progress bar (overlay).
    @State private var videos: [String: VideoPlaybackViewModel]

    /// 0 at rest, 1 at the point where letting go closes the viewer.
    private var pullProgress: CGFloat { min(max(pull / Self.closeDistance, 0), 1) }
    private static let closeDistance: CGFloat = 120

    /// Shown along the bottom, e.g. a post's whale / comment / save / share.
    var bottomBar: AnyView? = nil

    /// Off for Marketplace listings: a seller's photos aren't offered for
    /// download, so they're harder to lift into another listing.
    let allowsSaving: Bool

    init(items: [ChatMediaViewerItem], startIndex: Int = 0, bottomBar: AnyView? = nil, allowsSaving: Bool = true) {
        self.bottomBar = bottomBar
        self.allowsSaving = allowsSaving
        self.items = items
        _currentIndex = State(initialValue: min(max(0, startIndex), max(0, items.count - 1)))
        _videos = State(initialValue: Dictionary(uniqueKeysWithValues:
            items.filter(\.isVideo).map { ($0.id, VideoPlaybackViewModel(url: $0.url)) }))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - pullProgress * 0.75).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        if item.isVideo, let video = videos[item.id] {
                            VideoPlayerPage(video: video, isActive: currentIndex == index, onEdgeTap: toggleChrome)
                        } else {
                            ZoomableAsyncImage(url: item.url, isZoomed: $isZoomed, onSingleTap: toggleChrome)
                        }
                    }
                    .tag(index)
                    .contextMenu {
                        // Not on videos: holding an edge there plays at 2×.
                        if allowsSaving && !item.isVideo {
                            Button {
                                save(item)
                            } label: {
                                Label(Bundle.app.loc("Save to Photos"), systemImage: "square.and.arrow.down")
                            }
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
                    if allowsSaving, items.indices.contains(currentIndex) {
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
                if let video = currentVideo {
                    VideoProgressBar(video: video)
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomBar == nil ? 24 : 4)
                }
                if let bottomBar { bottomBar }
            }
            // One tap on the photo or video hides all of this (like Facebook); another brings it back.
            .opacity(chromeHidden ? 0 : 1 - pullProgress)
            .allowsHitTesting(!chromeHidden)
        }
        // See-through while pulled, so the screen behind shows as it fades.
        .presentationBackground(.clear)
        .mediaSaveStatus(saver)
        .statusBarHidden()
    }

    private var currentVideo: VideoPlaybackViewModel? {
        items.indices.contains(currentIndex) ? videos[items[currentIndex].id] : nil
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
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

/// Video page: plays while it's the current page. Tap the middle to pause or
/// play; tap an edge to hide or show the overlay; hold an edge for 2×.
private struct VideoPlayerPage: View {
    let video: VideoPlaybackViewModel
    let isActive: Bool
    var onEdgeTap: () -> Void = {}

    /// Flashes on a middle tap, stays while paused.
    @State private var showsPlayIcon = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PlayerLayerView(player: video.player)
                    .ignoresSafeArea()
                HStack(spacing: 0) {
                    edgeZone.frame(width: geo.size.width * 0.25)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture {
                            video.togglePlay()
                            showsPlayIcon = true
                        }
                    edgeZone.frame(width: geo.size.width * 0.25)
                }
                if showsPlayIcon || !video.isPlaying {
                    Image(systemName: video.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(22)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if video.isFast {
                    VStack {
                        Label("2×", systemImage: "forward.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(.top, 64)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear { if isActive { video.activate() } }
        .onChange(of: isActive) { _, active in active ? video.activate() : video.deactivate() }
        .onDisappear { video.deactivate() }
        .task(id: showsPlayIcon) {
            guard showsPlayIcon else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation { showsPlayIcon = false }
        }
    }

    /// Left or right quarter: tap toggles the overlay, holding plays at 2×.
    private var edgeZone: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { onEdgeTap() }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                // onPressingChanged fires at touch-down too; only a real hold speeds up.
                if !pressing { video.setFast(false) }
            })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in video.setFast(true) })
    }
}

/// `AVPlayerLayer` without the system controls, so taps and holds reach our gestures.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Elapsed / total and a draggable bar, under the video and above the post's bar.
private struct VideoProgressBar: View {
    let video: VideoPlaybackViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(VideoPlaybackViewModel.clock(video.currentSeconds))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 3)
                    Capsule().fill(Color.white).frame(width: geo.size.width * video.progress, height: 3)
                    Circle().fill(Color.white)
                        .frame(width: video.isScrubbing ? 14 : 10, height: video.isScrubbing ? 14 : 10)
                        .offset(x: geo.size.width * video.progress - (video.isScrubbing ? 7 : 5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !video.isScrubbing { video.beginScrubbing() }
                        video.scrub(to: value.location.x / max(geo.size.width, 1))
                    }
                    .onEnded { _ in video.endScrubbing() })
            }
            .frame(height: 24)
            Text(VideoPlaybackViewModel.clock(video.durationSeconds))
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundColor(.white)
    }
}

// MARK: - Zoomable image page

/// Fullscreen image: pinch to zoom (1x-4x), double-tap to toggle 2.5x,
/// drag to pan while zoomed. Resets when leaving the page.
private struct ZoomableAsyncImage: View {
    let url: URL
    /// Tells the viewer when the photo is zoomed in (so swipe-down stays off).
    @Binding var isZoomed: Bool
    var onSingleTap: () -> Void = {}

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
                        // After the double-tap, so a zoom isn't also read as a single tap.
                        .onTapGesture(count: 1) { onSingleTap() }
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
