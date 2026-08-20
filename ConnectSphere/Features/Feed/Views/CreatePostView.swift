import SwiftUI
import PhotosUI

struct CreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var privacy: PostPrivacy = .publicAll
    @State private var showPrivacyPicker = false
    /// Bỏ qua 1 lần detectAndFetchLink kế tiếp — dùng khi nạp content có sẵn
    /// lúc vào Edit mode, vì content đã bị strip URL nên detect sẽ xóa nhầm linkPreview.
    @State private var suppressNextLinkDetect = false

    // Media
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [PickedPostMedia] = []

    @State private var viewModel = CreatePostViewModel()

    /// Khi được set, view hoạt động ở chế độ Edit thay vì Create
    var editingPost: Post? = nil
    var onPostCreated: (() -> Void)?
    var onPostUpdated: ((Post) -> Void)?

    private var isEditMode: Bool { editingPost != nil }

    private var isPostDisabled: Bool {
        // Cho phép đăng khi có text HOẶC có media (post chỉ ảnh/video không cần caption)
        (content.trimmingCharacters(in: .whitespaces).isEmpty && selectedMedia.isEmpty)
            || viewModel.isPosting
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Composer ─────────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 16) {

                        // ── Row 1: Avatar + Name + Privacy chip  |  Mode badge ──
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(user: appState.currentUser ?? MockData.currentUser, size: 52)
                                .overlay(Circle().stroke(themeManager.theme.softFill, lineWidth: 3))

                            VStack(alignment: .leading, spacing: 8) {
                                Text(appState.currentUser?.name ?? "")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))

                                Button { showPrivacyPicker = true } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: privacy.icon)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(privacy.label(for: appState.currentMode))
                                            .font(.system(size: 13, weight: .semibold))
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .foregroundColor(themeManager.theme.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(themeManager.theme.softFill))
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            // Badge chế độ (chỉ icon) — sở thích vs công việc,
                            // tách hẳn khỏi icon privacy để không gây nhầm.
                            Image(systemName: appState.currentMode.glyph)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(themeManager.theme.primary)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(themeManager.theme.softFill))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // ── Row 2: Text box ────────────────────────────────────
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text(appState.currentMode == .hobby
                                     ? bundle.loc("What's on your mind?")
                                     : bundle.loc("Share a professional update..."))
                                    .font(.system(size: 16))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                                    .padding(.top, 12)
                                    .padding(.leading, 14)
                            }
                            TextEditor(text: $content)
                                .font(.system(size: 16))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .frame(minHeight: 150)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(AppColors.surface(colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 16)

                        // ── Media preview ──────────────────────────────────────
                        if !selectedMedia.isEmpty {
                            mediaPreview
                                .padding(.horizontal, 16)
                        }

                        // ── Link preview card ──────────────────────────────────
                        if viewModel.isFetchingLink {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading link preview...", bundle: bundle)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            .padding(.horizontal, 16)
                        } else if let preview = viewModel.linkPreview {
                            linkPreviewCard(preview)
                                .padding(.horizontal, 16)
                        }

                        // ── Photo/Video button ─────────────────────────────────
                        PhotosPicker(
                            selection: $selectedItems,
                            maxSelectionCount: 10,
                            matching: .any(of: [.images, .videos])
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(Color(hex: "#45BD62"))
                                Text("Photo / Video", bundle: bundle)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(AppColors.surface(colorScheme))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                    )
                            )
                        }
                        .onChange(of: selectedItems) { items in
                            Task { selectedMedia = await viewModel.loadSelectedMedia(items) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                }

                // ── Bottom bar ────────────────────────────────────────────────
                Divider()
                HStack {
                    Spacer()
                    Button {
                        handlePost()
                    } label: {
                        if viewModel.isPosting {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8).tint(.white)
                                Text("Posting...", bundle: bundle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppColors.textTertiary(colorScheme)))
                        } else {
                            Text(isEditMode ? bundle.loc("Save") : bundle.loc("Post"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(isPostDisabled
                                    ? AnyShapeStyle(AppColors.textDisabled(colorScheme))
                                    : AnyShapeStyle(themeManager.theme.primaryGradient)))
                                .shadow(color: isPostDisabled ? .clear : themeManager.theme.primary.opacity(0.35),
                                        radius: 8, x: 0, y: 4)
                        }
                    }
                    .disabled(isPostDisabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColors.surface(colorScheme))
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(isEditMode ? bundle.loc("Edit post") : bundle.loc("New post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            .onAppear {
                if let post = editingPost {
                    content = post.content
                    privacy = post.privacy
                    if let linkUrl = post.linkUrl {
                        suppressNextLinkDetect = true
                        viewModel.linkPreview = LinkPreviewDTO(
                            url: linkUrl,
                            title: post.articleTitle ?? linkUrl,
                            description: nil,
                            image: post.imageUrl,
                            siteName: nil
                        )
                    }
                }
            }
            .onChange(of: content) { _, newContent in
                if suppressNextLinkDetect {
                    suppressNextLinkDetect = false
                    return
                }
                viewModel.detectAndFetchLink(newContent)
            }
            .sheet(isPresented: $showPrivacyPicker) {
                PrivacyPickerSheet(selected: $privacy, mode: appState.currentMode)
            }
        }
    }

    // MARK: - Helpers

    private func handlePost() {
        if isEditMode {
            saveEdit()
        } else {
            viewModel.submitPost(
                content: content,
                mode: appState.currentMode,
                privacy: privacy,
                authToken: appState.authToken,
                selectedMedia: selectedMedia
            ) {
                onPostCreated?()
                dismiss()
            }
        }
    }

    private func saveEdit() {
        guard let post = editingPost else { return }
        viewModel.updatePost(
            postId: post.id,
            content: content,
            privacy: privacy,
            selectedMedia: selectedMedia,
            existingImageUrls: post.displayImageUrls
        ) { updatedPost in
            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": updatedPost])
            onPostUpdated?(updatedPost)
            dismiss()
        }
    }

    // MARK: - Link Preview

    private func linkPreviewCard(_ preview: LinkPreviewDTO) -> some View {
        HStack(spacing: 0) {
            if let imageStr = preview.image, let imageURL = URL(string: imageStr) {
                AsyncImage(url: imageURL) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipped()
                    } else {
                        Rectangle().fill(AppColors.base(colorScheme)).frame(width: 80, height: 80)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let site = preview.siteName {
                    Text(site.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                if let desc = preview.description {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { viewModel.linkPreview = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(10)
            }
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
    }

    // MARK: - Media

    private var mediaPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedMedia) { media in
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            if let preview = media.previewImage {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle().fill(Color.black.opacity(0.85))
                            }
                            if media.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                        }
                        .frame(width: selectedMedia.count == 1 ? 280 : 160,
                               height: selectedMedia.count == 1 ? 200 : 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            if let index = selectedMedia.firstIndex(where: { $0.id == media.id }) {
                                selectedMedia.remove(at: index)
                                if index < selectedItems.count {
                                    selectedItems.remove(at: index)
                                }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(6)
                    }
                }
            }
        }
    }
}

#Preview {
    CreatePostView()
        .environment(AppState())
}
