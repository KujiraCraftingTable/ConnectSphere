import SwiftUI

/// Quy ước media trong image_urls: đuôi .mp4/.mov = video, còn lại là ảnh
/// (backend upload chỉ cho phép 2 đuôi video này).
fileprivate extension String {
    var isVideoURL: Bool {
        let ext = URL(string: self)?.pathExtension.lowercased() ?? ""
        return ext == "mp4" || ext == "mov"
    }
}

/// Lưới media kiểu Facebook cho bài viết nhiều ảnh/video:
/// 1 media = full width · 2 = chia đôi · 3 = 1 lớn + 2 nhỏ · 4 = lưới 2×2
/// 5+ = lưới 2×2 với overlay "+N" ở ô cuối. Bấm mở viewer lướt ngang
/// (ảnh zoom được, video phát bằng AVPlayer).
struct PostPhotoGrid: View {
    let urls: [String]
    /// Chiều cao tổng của lưới (bài share nhúng dùng giá trị nhỏ hơn)
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

    /// Items cho viewer dùng chung của app (ảnh zoom, video AVPlayer)
    private var viewerItems: [ChatMediaViewerItem] {
        urls.enumerated().compactMap { index, urlString in
            guard let url = URL(string: urlString) else { return nil }
            return ChatMediaViewerItem(id: "\(index)-\(urlString)",
                                       url: url,
                                       isVideo: urlString.isVideoURL)
        }
    }

    // MARK: - Tile

    /// Một ô media; video = nền tối + nút play; overflow > 0 → phủ lớp tối "+N"
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

