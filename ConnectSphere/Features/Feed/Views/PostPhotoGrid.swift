import SwiftUI

/// Lưới ảnh kiểu Facebook cho bài viết nhiều ảnh:
/// 1 ảnh = full width · 2 = chia đôi · 3 = 1 lớn + 2 nhỏ · 4 = lưới 2×2
/// 5+ = lưới 2×2 với overlay "+N" ở ô cuối. Bấm ảnh mở viewer lướt ngang.
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
            PhotoPagerViewer(urls: urls, startIndex: target.index)
        }
    }

    // MARK: - Tile

    /// Một ô ảnh; overflow > 0 → phủ lớp tối "+N" (các ảnh còn lại)
    private func tile(_ index: Int, height: CGFloat, overflow: Int = 0) -> some View {
        Button {
            viewerTarget = ViewerTarget(index: index)
        } label: {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay(
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
                )
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

// MARK: - PhotoPagerViewer

/// Viewer toàn màn hình: lướt ngang giữa các ảnh, vuốt xuống hoặc bấm ✕ để đóng.
struct PhotoPagerViewer: View {
    @Environment(\.dismiss) var dismiss

    let urls: [String]
    @State private var index: Int

    init(urls: [String], startIndex: Int) {
        self.urls = urls
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { i in
                    AsyncImage(url: URL(string: urls[i])) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Header: đếm ảnh + nút đóng
            VStack {
                HStack {
                    Text("\(index + 1)/\(urls.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden()
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 60 { dismiss() }
            }
        )
    }
}
