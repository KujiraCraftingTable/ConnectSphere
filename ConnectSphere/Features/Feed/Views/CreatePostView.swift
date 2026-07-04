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

    // Media
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []

    @State private var viewModel = CreatePostViewModel()

    /// Khi được set, view hoạt động ở chế độ Edit thay vì Create
    var editingPost: Post? = nil
    var onPostCreated: (() -> Void)?
    var onPostUpdated: ((Post) -> Void)?

    private var isEditMode: Bool { editingPost != nil }

    private var isPostDisabled: Bool {
        // Cho phép đăng khi có text HOẶC có ảnh (post chỉ ảnh không cần caption)
        (content.trimmingCharacters(in: .whitespaces).isEmpty && selectedImages.isEmpty)
            || viewModel.isPosting
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Composer ─────────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 16) {

                        // ── Row 1: Avatar + Display name + Mode icon + Privacy chip ──
                        HStack(spacing: 12) {
                            AvatarView(user: appState.currentUser ?? MockData.currentUser, size: 52)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(appState.currentUser?.name ?? "")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))

                                HStack(spacing: 8) {
                                    Image(systemName: appState.currentMode == .friend ? "person.2.fill" : "briefcase.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(themeManager.theme.primary)
                                        .padding(7)
                                        .background(Circle().fill(themeManager.theme.softFill))

                                    Button { showPrivacyPicker = true } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: privacy.icon)
                                                .font(.system(size: 11))
                                            Text(privacy.label)
                                                .font(.system(size: 13, weight: .medium))
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 9, weight: .semibold))
                                        }
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(AppColors.elevated(colorScheme)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // ── Row 2: Text box ────────────────────────────────────
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text(appState.currentMode == .friend
                                     ? bundle.loc("Bạn đang nghĩ gì vậy?")
                                     : bundle.loc("Chia sẻ cập nhật chuyên nghiệp..."))
                                    .font(.system(size: 16))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                                    .padding(.top, 12)
                                    .padding(.leading, 14)
                            }
                            TextEditor(text: $content)
                                .font(.system(size: 16))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(AppColors.surface(colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 16)

                        // ── Media preview ──────────────────────────────────────
                        if !selectedImages.isEmpty {
                            mediaPreview
                                .padding(.horizontal, 16)
                        }

                        // ── Link preview card ──────────────────────────────────
                        if viewModel.isFetchingLink {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Đang tải link preview...", bundle: bundle)
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
                                Text("Ảnh / Video", bundle: bundle)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(AppColors.surface(colorScheme))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                    )
                            )
                        }
                        .onChange(of: selectedItems) { items in
                            Task { selectedImages = await viewModel.loadSelectedMedia(items) }
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
                                Text("Đang đăng...", bundle: bundle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppColors.textTertiary(colorScheme)))
                        } else {
                            Text(isEditMode ? bundle.loc("Lưu") : bundle.loc("Đăng"))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(isPostDisabled
                                    ? AppColors.textDisabled(colorScheme)
                                    : themeManager.theme.primary))
                        }
                    }
                    .disabled(isPostDisabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColors.surface(colorScheme))
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(isEditMode ? bundle.loc("Chỉnh sửa bài viết") : bundle.loc("Tạo bài viết"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Huỷ")) { dismiss() }
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            .onAppear {
                if let post = editingPost {
                    content = post.content
                    privacy = post.privacy
                }
            }
            .onChange(of: content) { _, newContent in
                viewModel.detectAndFetchLink(newContent)
            }
            .sheet(isPresented: $showPrivacyPicker) {
                PrivacyPickerSheet(selected: $privacy)
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
                selectedImages: selectedImages
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
            selectedImages: selectedImages,
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
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: selectedImages.count == 1 ? 280 : 160,
                                   height: selectedImages.count == 1 ? 200 : 160)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            selectedImages.remove(at: index)
                            if index < selectedItems.count {
                                selectedItems.remove(at: index)
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
