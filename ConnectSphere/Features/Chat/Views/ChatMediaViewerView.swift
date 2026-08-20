import SwiftUI
import AVKit

/// Một media mở trong viewer fullscreen (từ bubble chat hoặc gallery).
struct ChatMediaViewerItem: Identifiable {
    let id: String
    let url: URL
    let isVideo: Bool
}

/// Xem ảnh/video của đoạn chat fullscreen: pager ngang khi có nhiều media,
/// ảnh pinch-zoom + double-tap, video phát bằng AVPlayer.
struct ChatMediaViewerView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [ChatMediaViewerItem]
    @State private var currentIndex: Int

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
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Overlay: nút đóng + đếm trang
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
        .statusBarHidden()
    }
}

// MARK: - Video page

/// Trang video: tự phát khi là trang hiện tại, dừng khi lướt sang trang khác.
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

/// Ảnh fullscreen: pinch để zoom (1x–4x), double-tap bật/tắt 2.5x,
/// kéo để pan khi đang zoom. Reset khi rời trang.
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
                        .simultaneousGesture(panGesture)
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
