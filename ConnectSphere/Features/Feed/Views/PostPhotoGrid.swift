import SwiftUI

/// Convention for media in image_urls: .mp4/.mov extension = video, everything else is an image
/// (backend upload only allows these two video extensions).
fileprivate extension String {
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
    /// Total height of the grid (embedded shared posts use a smaller value)
    var gridHeight: CGFloat = 300

    @State private var viewerTarget: ViewerTarget?

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
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .fullScreenCover(item: $viewerTarget) { target in
            ChatMediaViewerView(items: viewerItems, startIndex: target.index)
        }
    }

    /// Items for the app's shared viewer (image zoom, video AVPlayer)
    private var viewerItems: [ChatMediaViewerItem] {
        urls.enumerated().compactMap { index, urlString in
            guard let url = URL(string: urlString) else { return nil }
            return ChatMediaViewerItem(id: "\(index)-\(urlString)",
                                       url: url,
                                       isVideo: urlString.isVideoURL)
        }
    }

    // MARK: - Tile

    /// A single media tile; video = dark background + play button; overflow > 0 → dark "+N" overlay
    private func tile(_ index: Int, height: CGFloat, overflow: Int = 0) -> some View {
        Button {
            viewerTarget = ViewerTarget(index: index)
        } label: {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    if urls[index].isVideoURL {
                        ZStack {
                            Color.black.opacity(0.85)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 34))
                                .foregroundColor(.white.opacity(0.92))
                        }
                    } else {
                        AsyncImage(url: URL(string: urls[index])) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                ZStack {
                                    Color.gray.opacity(0.15)
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray)
                                }
                            default:
                                ZStack {
                                    Color.gray.opacity(0.15)
                                    ProgressView()
                                }
                            }
                        }
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
    }
}

