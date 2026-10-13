import SwiftUI
import PhotosUI

struct CreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// The picked photo/video whose alt text is being written.
    @State private var altTarget: PickedPostMedia?
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

    // Hashtags — create mode only (PATCH /posts/:id doesn't accept them yet).
    @State private var hashtags: [String] = []
    @State private var hashtagController = HashtagInputController()

    @State private var viewModel = CreatePostViewModel()
    @State private var drafts = DraftsViewModel()
    /// The draft being continued: posting or saving again replaces it.
    @State private var draftId: String?
    @State private var showLeaveDialog = false
    @State private var showDraftPicker = false
    /// Set = the post is scheduled for this time instead of going out now.
    @State private var scheduleAt: Date?
    @State private var showSchedulePicker = false

    /// When set, the view operates in Edit mode instead of Create
    var editingPost: Post? = nil
    /// Opens the composer on a saved draft (Settings → Drafts).
    var draft: Post? = nil
    /// Called with the freshly-created post so the caller can insert it
    /// straight into whatever list it's displaying, instead of the caller
    /// having to reload from the server (and the user having to notice a
    /// silent background refresh) to see their own post appear.
    var onPostCreated: ((Post) -> Void)?
    var onPostUpdated: ((Post) -> Void)?

    private var isEditMode: Bool { editingPost != nil }

    /// Anything typed or attached — closing would lose it, so ask first.
    private var hasUnsavedWork: Bool {
        !isEditMode && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !selectedMedia.isEmpty || viewModel.linkPreview != nil)
    }

    /// The other feed drafts (not the one already open).
    private var feedDrafts: [Post] { drafts.drafts(inCommunity: nil).filter { $0.id != draftId } }

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
        let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                // Job posts are a Work-mode-only concept — hidden
                                // from the picker in Hobby mode (also enforced
                                // server-side, see PostService.createJobPost).
                                if appState.currentMode == .work {
                                    Text("Job", bundle: bundle).tag(PostType.job)
                                }
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
                        } else if postType == .job {
                            CreateJobSheet(
                                title:                    $composerViewModel.jobTitle,
                                company:                  $composerViewModel.jobCompany,
                                location:                 $composerViewModel.jobLocation,
                                employmentType:           $composerViewModel.jobEmploymentType,
                                salaryRange:              $composerViewModel.jobSalaryRange,
                                applicationDeadline:      $composerViewModel.jobApplicationDeadline,
                                showApplicationDeadline:  $composerViewModel.showJobApplicationDeadline
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                        }

                        if postType == .text {
                            // ── Media preview ────────────────────────────────
                            if !selectedMedia.isEmpty || viewModel.pendingMediaCount > 0 {
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

                        // ── Hashtags (create mode only — the update-post endpoint
                        // doesn't accept them). Applies to all post types. ───────
                        if !isEditMode {
                            HashtagInputView(hashtags: $hashtags, controller: hashtagController)
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
                                Task {
                                    selectedMedia = await viewModel.loadSelectedMedia(items, keeping: selectedMedia) {
                                        selectedMedia = $0
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                        }
                    }
                }

                // ── Bottom bar ────────────────────────────────────────────────
                Divider()
                HStack {
                    if !isEditMode {
                        if let scheduleAt {
                            ScheduleLine(date: scheduleAt, onEdit: { showSchedulePicker = true },
                                         onClear: { self.scheduleAt = nil })
                        } else {
                            Button { showSchedulePicker = true } label: {
                                Image(systemName: "clock")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .frame(width: 40, height: 40)
                            }
                            .accessibilityLabel(Text("Schedule post", bundle: bundle))
                        }
                    }
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
                            Text(isEditMode ? bundle.loc("Save") : bundle.loc(scheduleAt == nil ? "Post" : "Schedule"))
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
                    Button(bundle.loc("Cancel")) {
                        if hasUnsavedWork { showLeaveDialog = true } else { dismiss() }
                    }
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .confirmationDialog(bundle.loc(draftId == nil ? "Save this post as a draft?" : "Save your changes to this draft?"),
                                        isPresented: $showLeaveDialog, titleVisibility: .visible) {
                        if !isPostDisabled {
                            Button(bundle.loc("Save draft")) { savePost(as: .draft) }
                        }
                        Button(bundle.loc(draftId == nil ? "Discard" : "Discard changes"), role: .destructive) { dismiss() }
                        Button(bundle.loc("Keep editing"), role: .cancel) {}
                    }
                }
                if !isEditMode && !feedDrafts.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(String(format: bundle.loc("Drafts (%lld)"), feedDrafts.count)) { showDraftPicker = true }
                            .foregroundColor(themeManager.theme.primary)
                    }
                }
            }
            .sheet(isPresented: $showSchedulePicker) {
                SchedulePickerSheet(initial: scheduleAt) { scheduleAt = $0 }
            }
            .sheet(isPresented: $showDraftPicker) {
                DraftPickerSheet(drafts: feedDrafts) { picked in loadDraft(picked) }
            }
            .task {
                guard !isEditMode else { return }
                await drafts.load()
            }
            .onAppear {
                if let draft, draftId == nil { loadDraft(draft) }
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
            // Upload or post failure (feed text posts) — the composer stays open
            // with everything intact so the user can retry or remove the media.
            .alert(
                bundle.loc("Couldn't post"),
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button(bundle.loc("OK"), role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    // MARK: - Helpers

    private func handlePost() {
        if isEditMode {
            saveEdit()
        } else {
            savePost(as: scheduleAt.map(PublishChoice.schedule) ?? .now)
        }
    }

    /// Posts now, or saves a draft. Opened from a draft, either one replaces
    /// it on the server (`replaces_draft`).
    private func savePost(as publish: PublishChoice) {
        // Flush whatever's still typed-but-uncommitted in the hashtag field
        // before reading `hashtags` — otherwise a hashtag typed right before
        // tapping Post (no space/return/suggestion tap) is silently dropped.
        hashtagController.commitPending(into: &hashtags)
        let finish: (Post) -> Void = { post in
            if publish.isLive {
                // Broadcast beyond just this composer's own caller — e.g.
                // `AppState.currentUser.postCount` and a `ProfileViewModel`
                // that's still alive in memory (Profile tab visited earlier,
                // not recreated) have no other way to learn a new post exists
                // when creation happens from a DIFFERENT screen (Home Feed).
                NotificationCenter.default.post(name: .postCreated, object: nil, userInfo: ["post": post])
                onPostCreated?(post)
            }
            if !publish.isLive || draftId != nil {
                NotificationCenter.default.post(name: .draftsChanged, object: nil)
            }
            dismiss()
        }
        if postType == .text {
            viewModel.submitPost(
                content: content,
                mode: appState.currentMode,
                privacy: privacy,
                authToken: appState.authToken,
                selectedMedia: selectedMedia,
                hashtags: hashtags,
                publish: publish,
                replacesDraft: draftId,
                onSuccess: finish
            )
        } else {
            composerViewModel.publish = publish
            composerViewModel.replacesDraftId = draftId
            Task<Void, Never>(name: nil) {
                await composerViewModel.submitPost(
                    communityId: nil,
                    token: appState.authToken ?? "",
                    mode: appState.currentMode,
                    privacy: privacy,
                    hashtags: hashtags
                ) { communityPost in finish(feedPost(from: communityPost)) }
            }
        }
    }

    /// Fills the composer from a saved draft.
    private func loadDraft(_ d: Post) {
        draftId = d.id
        suppressNextLinkDetect = d.linkUrl != nil
        content = d.content
        privacy = d.privacy
        postType = d.postType
        hashtags = d.tags
        selectedItems = []
        selectedMedia = PickedPostMedia.remote(d.imageUrls, alts: d.imageAlts)
        viewModel.linkPreview = d.linkUrl.map {
            LinkPreviewDTO(url: $0, title: d.articleTitle ?? $0, description: nil, image: d.imageUrl, siteName: nil)
        }
        composerViewModel.load(d)
        scheduleAt = d.publishStatus == "scheduled" ? d.publishAt : nil
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
            eventData:     communityPost.eventData,
            jobData:       communityPost.jobData
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

    /// One item fills the row; several share it as squares. Loading tiles
    /// count too, so the row doesn't jump when they turn into the media.
    private var tileSize: CGSize {
        selectedMedia.count + viewModel.pendingMediaCount == 1 ? CGSize(width: 280, height: 200) : CGSize(width: 160, height: 160)
    }

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
                            } else if let remote = media.remoteURL, !media.isVideo {
                                // A draft's photo, already uploaded.
                                AsyncImage(url: APIConfig.mediaURL(remote)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Rectangle().fill(Color.gray.opacity(0.2))
                                }
                            } else {
                                Rectangle().fill(Color.black.opacity(0.85))
                            }
                            if media.isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                        }
                        .frame(width: tileSize.width, height: tileSize.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomLeading) {
                            AltTextChip(hasText: !media.altText.isEmpty) { altTarget = media }
                        }

                        Button {
                            // A draft's media isn't in the picker selection, so
                            // match the picker item itself, not the position.
                            selectedMedia.removeAll { $0.id == media.id }
                            if let item = media.pickerItem { selectedItems.removeAll { $0 == item } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(6)
                    }
                }
                // One blinking tile per picked item still loading.
                ForEach(0..<viewModel.pendingMediaCount, id: \.self) { _ in
                    MediaLoadingTile(width: tileSize.width, height: tileSize.height)
                }
            }
        }
        .sheet(item: $altTarget) { media in
            AltTextEditorSheet(preview: media.previewImage, isVideo: media.isVideo, initialText: media.altText) { text in
                if let index = selectedMedia.firstIndex(where: { $0.id == media.id }) { selectedMedia[index].altText = text }
            }
        }
    }
}

#Preview {
    CreatePostView()
        .environment(AppState())
}
