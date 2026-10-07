import SwiftUI
import AVKit

/// A single media item opened in the fullscreen viewer (from a chat bubble or the gallery).
struct ChatMediaViewerItem: Identifiable {
    let id: String
    let url: URL
    let isVideo: Bool
}

/// View a chat's images/videos fullscreen: horizontal pager when there are multiple media items,
/// images support pinch-zoom + double-tap, videos play via AVPlayer.
struct ChatMediaViewerView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [ChatMediaViewerItem]
    @State private var currentIndex: Int
    @State private var saver = MediaSaveViewModel()

    init(items: [ChatMediaViewerItem], startIndex: Int = 0) {
        self.items = items
        _currentIndex = State(initialValue: min(max(0, startIndex), max(0, items.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        if item.isVideo {
                            VideoPlayerPage(url: item.url, isActive: currentIndex == index)
                        } else {
                            ZoomableAsyncImage(url: item.url)
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

            // Overlay: close button + page counter
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    Spacer()
                    if items.indices.contains(currentIndex) {
                        Button { save(items[currentIndex]) } label: {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .disabled(saver.isSaving)
                        .accessibilityLabel(Text(Bundle.app.loc("Save to Photos")))
                    }
                    if items.count > 1 {
                        Text("\(currentIndex + 1)/\(items.count)")
                            .font(.system(size: 14, weight: .semibold))
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
        }
        .mediaSaveStatus(saver)
        .statusBarHidden()
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
    }

    private var failurePlaceholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 40))
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
