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

    // Post type (Phase 2: Feed can now post polls/events, not just text) —
    // hidden entirely in edit mode, which only supports editing text posts.
    @State private var postType: PostType = .text
    @State private var composerViewModel = PostComposerViewModel()
    /// Skips the next single detectAndFetchLink call — used when loading existing content
    /// on entering Edit mode, since the content had its URL stripped already, so detecting
    /// again would wrongly clear linkPreview.
    @State private var suppressNextLinkDetect = false

    // Media
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [PickedPostMedia] = []

    // Hashtags + AI-tag visibility — create mode only (PATCH /posts/:id doesn't
    // accept these fields yet). `showAiTags` is a plain, non-persisted @State so
    // the toggle always resets to off whenever the composer opens fresh.
    @State private var hashtags: [String] = []
    @State private var hashtagController = HashtagInputController()
    @State private var showAiTags = false

    @State private var viewModel = CreatePostViewModel()

    /// When set, the view operates in Edit mode instead of Create
    var editingPost: Post? = nil
    /// Called with the freshly-created post so the caller can insert it
    /// straight into whatever list it's displaying, instead of the caller
    /// having to reload from the server (and the user having to notice a
    /// silent background refresh) to see their own post appear.
    var onPostCreated: ((Post) -> Void)?
    var onPostUpdated: ((Post) -> Void)?

    private var isEditMode: Bool { editingPost != nil }

    /// Edit mode only: does the post being edited ALREADY have media or a link that
    /// hasn't been changed? `selectedMedia`/`linkPreview` only ever reflect NEWLY
    /// picked media/a newly-detected link in this view — edit mode never seeds them
    /// from the existing post (images stay server-side, referenced by URL, until the
    /// user picks new ones), so without this a caption-less media/link post being
    /// edited would look content-less and Save would be wrongly disabled forever.
    private var editingPostHasExistingMediaOrLink: Bool {
        guard isEditMode else { return false }
        return !(editingPost?.displayImageUrls.isEmpty ?? true) || editingPost?.linkUrl != nil
    }

    private var isPostDisabled: Bool {
        // Poll/event validity (min 2 options, event title + future start time)
        // is delegated to composerViewModel.isValid — same rule the Community
        // composer already enforces for identical post types.
        guard postType == .text else {
            return !composerViewModel.isValid || composerViewModel.isPosting
        }
        // Allow posting when there's text OR media/link (an image/video/link-only post
        // doesn't need a caption) — in edit mode, media/link the post already has also
        // counts, not just newly picked media or a newly detected link.
        let hasContent = !content.trimmingCharacters(in: .whitespaces).isEmpty
            || !selectedMedia.isEmpty
            || viewModel.linkPreview != nil
            || editingPostHasExistingMediaOrLink
        return !hasContent || viewModel.isPosting
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

                            // Mode badge (icon only) — hobby vs work,
                            // kept fully separate from the privacy icon to avoid confusion.
                            Image(systemName: appState.currentMode.glyph)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(themeManager.theme.primary)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(themeManager.theme.softFill))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // ── Post type picker (create mode only — editing an
                        // existing post never changes its type) ────────────────
                        if !isEditMode {
                            Picker("Post type", selection: $postType) {
                                Text("Text", bundle: bundle).tag(PostType.text)
                                Text("Poll", bundle: bundle).tag(PostType.poll)
                                Text("Event", bundle: bundle).tag(PostType.event)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .onChange(of: postType) { _, new in composerViewModel.postType = new }
                        }

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

                        // ── Poll/Event inline sections — same @Binding-only
                        // components CommunityCreatePostView uses, zero changes
                        // needed since they're already post-type-agnostic. ─────
                        if postType == .poll {
                            CreatePollSheet(
                                options:     $composerViewModel.pollOptions,
                                endsAt:      $composerViewModel.pollEndsAt,
                                showEndDate: $composerViewModel.showPollEndDate
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                        } else if postType == .event {
                            CreateEventSheet(
                                title:       $composerViewModel.eventTitle,
                                location:    $composerViewModel.eventLocation,
                                startsAt:    $composerViewModel.eventStartsAt,
                                endsAt:      $composerViewModel.eventEndsAt,
                                showEndDate: $composerViewModel.showEventEndDate
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                        }

                        if postType == .text {
                            // ── Media preview ────────────────────────────────
                            if !selectedMedia.isEmpty {
                                mediaPreview
                                    .padding(.horizontal, 16)
                            }

                            // ── Link preview card ────────────────────────────
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
                        }

                        // ── Hashtags + AI-tag visibility (create mode only — the
                        // update-post endpoint doesn't accept these fields).
                        // Applies to all post types — backend accepts hashtags/
                        // show_ai_tags on text/poll/event alike. ────────────────
                        if !isEditMode {
                            HashtagInputView(hashtags: $hashtags, controller: hashtagController)
                                .padding(.horizontal, 16)

                            aiTagsToggle
                                .padding(.horizontal, 16)
                        }

                        // ── Photo/Video button (text posts only — backend only
                        // accepts image_urls on post_type='text') ──────────────
                        if postType == .text {
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
                // Keep composerViewModel.content mirrored regardless of
                // postType — it's the single field composerViewModel.isValid
                // (poll/event validation) and submitPoll/submitEvent both read.
                composerViewModel.content = newContent
                if suppressNextLinkDetect {
                    suppressNextLinkDetect = false
                    return
                }
                if postType == .text {
                    viewModel.detectAndFetchLink(newContent)
                }
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
        } else if postType == .text {
            // Flush whatever's still typed-but-uncommitted in the hashtag field
            // before reading `hashtags` — otherwise a hashtag typed right before
            // tapping Post (no space/return/suggestion tap) is silently dropped.
            hashtagController.commitPending(into: &hashtags)
            viewModel.submitPost(
                content: content,
                mode: appState.currentMode,
                privacy: privacy,
                authToken: appState.authToken,
                selectedMedia: selectedMedia,
                hashtags: hashtags,
                showAiTags: showAiTags
            ) { post in
                // Broadcast beyond just this composer's own caller — e.g.
                // `AppState.currentUser.postCount` and a `ProfileViewModel`
                // that's still alive in memory (Profile tab visited earlier,
                // not recreated) have no other way to learn a new post exists
                // when creation happens from a DIFFERENT screen (Home Feed).
                NotificationCenter.default.post(name: .postCreated, object: nil, userInfo: ["post": post])
                onPostCreated?(post)
                dismiss()
            }
        } else {
            handlePollOrEventPost()
        }
    }

    /// Poll/event submission — routed through PostComposerViewModel with
    /// `communityId: nil` so it posts straight to the Feed (`POST /posts`)
    /// instead of a community. The response decodes as `CommunityPost`
    /// (composer's shared decode path across Feed/Community); converted to a
    /// Feed `Post` here since that's what this screen's callbacks expect —
    /// the author is always the current user, so no round-trip needed for it.
    private func handlePollOrEventPost() {
        hashtagController.commitPending(into: &hashtags)
        Task<Void, Never>(name: nil) {
            await composerViewModel.submitPost(
                communityId: nil,
                token: appState.authToken ?? "",
                mode: appState.currentMode,
                privacy: privacy,
                hashtags: hashtags,
                showAiTags: showAiTags
            ) { communityPost in
                let post = feedPost(from: communityPost)
                NotificationCenter.default.post(name: .postCreated, object: nil, userInfo: ["post": post])
                onPostCreated?(post)
                dismiss()
            }
        }
    }

    /// Adapts a `CommunityPost` (what PostComposerViewModel's shared submit
    /// path returns) into a Feed `Post` for this screen's Post-typed
    /// callbacks. mode/privacy come from local composer state (already known
    /// — this IS what was just submitted), not decoded from the response.
    private func feedPost(from communityPost: CommunityPost) -> Post {
        Post(
            id:            communityPost.id,
            author:        appState.currentUser ?? MockData.currentUser,
            content:       communityPost.content,
            timestamp:     communityPost.createdAt,
            mode:          appState.currentMode,
            privacy:       privacy,
            linkUrl:       communityPost.linkUrl,
            imageUrl:      communityPost.imageUrl,
            imageUrls:     communityPost.imageUrls,
            likeCount:     communityPost.likeCount,
            commentCount:  communityPost.commentCount,
            shareCount:    0,
            isLiked:       communityPost.isLiked,
            isSaved:       false,
            articleTitle:  communityPost.articleTitle,
            tags:          communityPost.tags,
            sharedPostId:  nil,
            sharedPost:    nil,
            postType:      communityPost.postType,
            pollData:      communityPost.pollData,
            eventData:     communityPost.eventData
        )
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

    // MARK: - AI tags toggle

    /// Always starts off each time the composer opens (not persisted as a preference) —
    /// this post's AI tags only show up if the user actively turns it on for that specific post.
    private var aiTagsToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $showAiTags) {
                Text("Show AI-generated tags", bundle: bundle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(themeManager.theme.primary)

            Text("AI tags stay hidden unless you turn this on for this post.", bundle: bundle)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textTertiary(colorScheme))
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
