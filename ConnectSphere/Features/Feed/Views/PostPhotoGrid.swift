import SwiftUI

/// Convention for media in image_urls: .mp4/.mov extension = video, everything else is an image
/// (backend upload only allows these two video extensions).
extension String {
    var isVideoURL: Bool {
        let ext = URL(string: self)?.pathExtension.lowercased() ?? ""
        return ext == "mp4" || ext == "mov"
    }
}

/// Facebook-style media grid for posts with multiple images/videos:
/// 1 media = full width · 2 = split in half · 3 = 1 large + 2 small · 4 = 2×2 grid
/// 5+ = 2×2 grid with a "+N" overlay on the last tile. Tapping opens a swipeable
/// viewer (images zoom, video plays via AVPlayer).
struct PostPhotoGrid: View {
    let urls: [String]
    /// Alt text per url ('' or missing = none).
    var alts: [String] = []
    /// Total height of the grid (embedded shared posts use a smaller value)
    var gridHeight: CGFloat = 300

    @State private var viewerTarget: ViewerTarget?
    /// Tiles whose image failed to load: tapping retries instead of opening the viewer.
    @State private var failed: Set<Int> = []
    @State private var retries: [Int: Int] = [:]
    @State private var saver = MediaSaveViewModel()

    private struct ViewerTarget: Identifiable {
        let id = UUID()
        let index: Int
    }

    private let spacing: CGFloat = 2

    var body: some View {
        Group {
            switch urls.count {
            case 0:
                EmptyView()
            case 1:
                tile(0, height: gridHeight)
            case 2:
                HStack(spacing: spacing) {
                    tile(0, height: gridHeight * 0.7)
                    tile(1, height: gridHeight * 0.7)
                }
            case 3:
                HStack(spacing: spacing) {
                    tile(0, height: gridHeight * 0.85)
                    VStack(spacing: spacing) {
                        tile(1, height: (gridHeight * 0.85 - spacing) / 2)
                        tile(2, height: (gridHeight * 0.85 - spacing) / 2)
                    }
                }
            default:
                let half = (gridHeight - spacing) / 2
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        tile(0, height: half)
                        tile(1, height: half)
                    }
                    HStack(spacing: spacing) {
                        tile(2, height: half)
                        tile(3, height: half, overflow: urls.count - 4)
                    }
                }
            }
        }
        .clipped()
        .mediaSaveStatus(saver)
        .fullScreenCover(item: $viewerTarget) { target in
            ChatMediaViewerView(items: viewerItems, startIndex: target.index)
        }
    }

    /// Items for the app's shared viewer (image zoom, video AVPlayer)
    private var viewerItems: [ChatMediaViewerItem] {
        urls.enumerated().compactMap { index, urlString in
            guard let url = APIConfig.mediaURL(urlString) else { return nil }
            return ChatMediaViewerItem(id: "\(index)-\(urlString)",
                                       url: url,
                                       isVideo: urlString.isVideoURL)
        }
    }

    // MARK: - Tile

    /// A single media tile; video = dark background + play button; overflow > 0 → dark "+N" overlay
    private func alt(_ index: Int) -> String {
        index < alts.count ? alts[index] : ""
    }

    /// Stands in for a photo until it arrives — or if it never does — so the
    /// reader knows something belongs here, and what, when there's alt text.
    private func placeholder(_ index: Int, failed: Bool) -> some View {
        let alt = alt(index)
        return ZStack {
            Color.gray.opacity(0.15)
            VStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .font(.system(size: 18))
                if !alt.isEmpty {
                    Text(alt)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                if failed {
                    Text("Couldn't load · Tap to retry", bundle: .app)
                        .font(.system(size: 12, weight: .semibold))
                } else if alt.isEmpty {
                    ProgressView()
                }
            }
            .foregroundColor(.secondary)
            .padding(12)
        }
    }

    private func tile(_ index: Int, height: CGFloat, overflow: Int = 0) -> some View {
        let isVideo = urls[index].isVideoURL
        let description = alt(index)
        return Button {
            if failed.contains(index) {
                failed.remove(index)
                retries[index, default: 0] += 1
            } else {
                viewerTarget = ViewerTarget(index: index)
            }
        } label: {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    if urls[index].isVideoURL {
                        VideoPosterView(url: APIConfig.mediaURL(urls[index]))
                    } else {
                        RemoteImage(url: APIConfig.thumbnailURL(urls[index])) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                                    .onAppear { failed.remove(index) }
                            case .failure:
                                placeholder(index, failed: true)
                                    .onAppear { failed.insert(index) }
                            default:
                                placeholder(index, failed: false)
                            }
                        }
                        // A new identity re-runs the load on "Tap to retry".
                        .id("\(urls[index])#\(retries[index, default: 0])")
                    }
                }
                .clipped()
                .overlay {
                    if overflow > 0 {
                        ZStack {
                            Color.black.opacity(0.45)
                            Text("+\(overflow)")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(description.isEmpty
            ? Text(isVideo ? "Video" : "Photo", bundle: .app)
            : Text(description))
        .contextMenu {
            Button {
                guard let url = APIConfig.mediaURL(urls[index]) else { return }
                Task { await saver.save([.init(url: url, isVideo: urls[index].isVideoURL)]) }
            } label: {
                Label(Bundle.app.loc("Save to Photos"), systemImage: "square.and.arrow.down")
            }
        }
    }
}

