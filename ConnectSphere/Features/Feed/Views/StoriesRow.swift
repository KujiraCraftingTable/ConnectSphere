import SwiftUI
import PhotosUI

/// The real stories row: your own story + stories from connections (24h).
/// Tapping a bubble opens StoryViewerView; the + button posts a new story.
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
    private let postRepo  = PostRepository()   // reuses the shared image upload endpoint

    private var myGroup: StoryGroup? {
        groups.first { $0.author.id == appState.currentUser?.id }
    }

    /// Unseen-first: an author with any unseen story sorts before one whose
    /// stories are all already viewed. `sorted` is stable, so within each of
    /// those two buckets authors keep whatever order the server returned.
    private var otherGroups: [StoryGroup] {
        groups.filter { $0.author.id != appState.currentUser?.id }
            .sorted { $0.hasUnseen && !$1.hasUnseen }
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
                // Reload to update the seen-state ring after closing the viewer
                Task { await load() }
            }
        }
    }

    // MARK: - Bubbles

    /// "Your story" bubble: tapping the avatar opens your own story (if any), + posts a new one
    private var myStoryBubble: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    if let mine = myGroup { selectedGroup = mine }
                } label: {
                    ZStack {
                        // A ring only when there's an actual story to show —
                        // no story at all should look like no story at all,
                        // not a dim/neutral placeholder ring (that previously
                        // used AppColors.borderDefault, a near-transparent
                        // 0.09-0.10 opacity hairline — barely visible against
                        // a light background, which is exactly what read as
                        // "faded" rather than as an intentional neutral state).
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
