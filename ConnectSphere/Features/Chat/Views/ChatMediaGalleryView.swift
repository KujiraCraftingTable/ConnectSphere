import SwiftUI

/// Target mở viewer từ grid — giữ index trang bắt đầu
private struct GalleryViewerTarget: Identifiable {
    let id = UUID()
    let startIndex: Int
}

/// Grid of all images/videos shared in a conversation.
/// Tap một ô để mở viewer fullscreen (lướt ngang qua toàn bộ media).
struct ChatMediaGalleryView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let viewModel: ChatSettingsViewModel

    @State private var viewerTarget: GalleryViewerTarget?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    /// Toàn bộ media của grid dưới dạng item cho viewer (bỏ URL hỏng)
    private var viewerItems: [ChatMediaViewerItem] {
        viewModel.media.compactMap { item in
            guard let url = item.absoluteMediaURL() else { return nil }
            return ChatMediaViewerItem(id: item.id, url: url, isVideo: item.messageType == .video)
        }
    }

    var body: some View {
        ScrollView {
            if viewModel.isLoadingMedia && viewModel.media.isEmpty {
                ProgressView().padding(.top, 60)
            } else if viewModel.media.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.media) { item in
                        mediaCell(item)
                    }
                }
                .padding(2)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Photos & videos"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadMedia() }
        .fullScreenCover(item: $viewerTarget) { target in
            ChatMediaViewerView(items: viewerItems, startIndex: target.startIndex)
        }
    }

    private func mediaCell(_ item: ChatMediaItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.messageType == .image, let url = item.absoluteMediaURL() {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        case .failure:          placeholder(icon: "photo")
                        default:                ProgressView()
                        }
                    }
                } else {
                    placeholder(icon: "play.circle.fill")
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { openViewer(for: item) }
    }

    /// Mở viewer tại đúng vị trí ô được bấm (map theo id vì viewerItems có thể bỏ URL hỏng)
    private func openViewer(for item: ChatMediaItem) {
        let index = viewerItems.firstIndex { $0.id == item.id } ?? 0
        viewerTarget = GalleryViewerTarget(startIndex: index)
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            AppColors.elevated(colorScheme)
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No photos or videos yet", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
