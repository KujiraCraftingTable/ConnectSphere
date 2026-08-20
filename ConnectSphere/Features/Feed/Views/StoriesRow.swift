import SwiftUI
import PhotosUI

/// Hàng stories thật: tin của mình + tin từ connections (24h).
/// Bấm bubble mở StoryViewerView; nút + để đăng tin mới.
struct StoriesRow: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var groups: [StoryGroup] = []
    @State private var selectedGroup: StoryGroup?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPosting = false

    private let storyRepo = StoryRepository()
    private let postRepo  = PostRepository()   // dùng chung endpoint upload ảnh

    private var myGroup: StoryGroup? {
        groups.first { $0.author.id == appState.currentUser?.id }
    }

    private var otherGroups: [StoryGroup] {
        groups.filter { $0.author.id != appState.currentUser?.id }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                myStoryBubble
                ForEach(otherGroups) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        storyBubble(group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .task { await load() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await postStory(from: item) }
        }
        .fullScreenCover(item: $selectedGroup) { group in
            StoryViewerView(group: group) {
                // Reload để cập nhật ring đã xem sau khi đóng viewer
                Task { await load() }
            }
        }
    }

    // MARK: - Bubbles

    /// Bubble "Tin của bạn": bấm avatar mở tin của mình (nếu có), nút + đăng tin mới
    private var myStoryBubble: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    if let mine = myGroup { selectedGroup = mine }
                } label: {
                    ZStack {
                        if myGroup?.hasUnseen == true {
                            Circle()
                                .stroke(themeManager.theme.primary, lineWidth: 2.5)
                                .frame(width: 68, height: 68)
                        } else if myGroup != nil {
                            Circle()
                                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 2.5)
                                .frame(width: 68, height: 68)
                        }
                        if let me = appState.currentUser {
                            AvatarView(user: me, size: 60)
                        }
                    }
                    .frame(width: 68, height: 68)
                }
                .buttonStyle(.plain)
                .disabled(myGroup == nil)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    ZStack {
                        Circle().fill(themeManager.theme.primary).frame(width: 22, height: 22)
                        if isPosting {
                            ProgressView().scaleEffect(0.5).tint(.white)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .offset(x: 2, y: 2)
            }
            Text("Your story", bundle: bundle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
        }
        .frame(width: 70)
    }

    private func storyBubble(_ group: StoryGroup) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(
                        group.hasUnseen
                            ? themeManager.theme.primary
                            : AppColors.borderDefault(colorScheme),
                        lineWidth: 2.5
                    )
                    .frame(width: 68, height: 68)
                AvatarView(user: group.author, size: 60)
            }
            Text(group.author.name.components(separatedBy: " ").first ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
        }
        .frame(width: 70)
    }

    // MARK: - Data

    private func load() async {
        if let stories = try? await storyRepo.fetchStories() {
            groups = groupStories(stories)
        }
    }

    private func postStory(from item: PhotosPickerItem) async {
        isPosting = true
        defer { isPosting = false; pickerItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85),
              let imageUrl = try? await postRepo.uploadImage(jpeg) else { return }

        try? await storyRepo.createStory(imageUrl: imageUrl)
        await load()
    }
}
