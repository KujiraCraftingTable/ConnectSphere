import SwiftUI
import PhotosUI

struct CreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(UndoToastPresenter.self) private var toast

    /// The picked photo/video whose alt text is being written.
    @State private var altTarget: PickedPostMedia?
    @State private var content = ""
    @State private var privacy: PostPrivacy = .publicAll
    @State private var showPrivacyPicker = false
    /// The official account's cross-post: the same post in Hobby and Work.
    @State private var postInBothModes = false

    // Post type (Phase 2: Feed can now post polls/events, not just text),
    // hidden entirely in edit mode, which only supports editing text posts.
    @State private var postType: PostType = .text
    @State private var composerViewModel = PostComposerViewModel()
    /// Skips the next single detectAndFetchLink call. Used when loading existing content
    /// on entering Edit mode, since the content had its URL stripped already, so detecting
    /// again would wrongly clear linkPreview.
    @State private var suppressNextLinkDetect = false

    // Media
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [PickedPostMedia] = []

    // Hashtags, create mode only (PATCH /posts/:id doesn't accept them yet).
    /// Finished `#tags` leave the text and sit here as chips, as a link leaves it
    /// for its card; a tag still being typed is read from the text.
    @State private var typedTags: [String] = []
    private var hashtags: [String] {
        var seen = Set<String>()
        return (typedTags + PostText.tags(in: content)).filter { seen.insert($0.lowercased()).inserted }
    }

    @State private var viewModel = CreatePostViewModel()
    @State private var drafts = DraftsViewModel()
    /// The draft being continued: posting or saving again replaces it.
    @State private var draftId: String?
    @State private var showLeaveDialog = false
    /// The leave question came from tapping Sell: whatever is chosen, New
    /// listing opens after this composer closes.
    @State private var leavingForSell = false
    @State private var showDraftPicker = false
    /// Set = the post is scheduled for this time instead of going out now.
    @State private var scheduleAt: Date?
    @State private var showSchedulePicker = false

    /// Posts into this community instead of the feed: its mode, always
    /// public, and the community's own endpoint.
    var community: Community? = nil
    /// When set, the view operates in Edit mode instead of Create
    var editingPost: Post? = nil
    /// Opens the composer on a saved draft (Settings → Drafts).
    var draft: Post? = nil
    /// Called with the freshly-created post so the caller can insert it
    /// straight into whatever list it's displaying, instead of the caller
    /// having to reload from the server (and the user having to notice a
    /// silent background refresh) to see their own post appear.
    var onPostCreated: ((Post) -> Void)?
    /// Sell tapped: the presenter closes this composer and opens New listing
    /// in its place. Without it, New listing stacks on top of the composer.
    var onSell: (() -> Void)? = nil
    var onPostUpdated: ((Post) -> Void)?
    /// Opens on this type, e.g. Job from the Jobs tab's "+". Ignored where the
    /// type isn't offered (Job needs Work mode and a verified HR).
    var initialPostType: PostType = .text

    private var isEditMode: Bool { editingPost != nil }

    /// Who sees a community post: members only unless the poster picks Public.
    @State private var communityAudience: CommunityAudience = .members
    /// The Sell form, from the community composer's "Sell" tab.
    @State private var showSell = false
    /// The community this post goes to (new) or is in (editing).
    private var target: (name: String, icon: String, isPrivate: Bool)? {
        if let community { return (community.name, community.iconEmoji, community.privacy == .private) }
        if let c = editingPost?.community { return (c.name, c.iconEmoji, c.privacy == "private") }
        return nil
    }

    /// A community's mode comes from its type; the feed's from the app.
    private var effectiveMode: AppMode {
        community.map { _ in .hobby } ?? appState.currentMode
    }

    private var isPosting: Bool { viewModel.isPosting || composerViewModel.isPosting }

    private var takesMedia: Bool { postType == .text }
    /// A post shows its link card or its photos, not both, so a link turns photos off.
    private var photosBlockedByLink: Bool { viewModel.linkPreview != nil }

    /// Everything the person can change on this screen, compared with how it
    /// looked when it opened, to know whether Cancel would lose anything.
    private var editSignature: [String] {
        [content.trimmingCharacters(in: .whitespacesAndNewlines),
         hashtags.map { $0.lowercased() }.sorted().joined(separator: ","),
         privacy.rawValue,
         viewModel.linkPreview?.url ?? "",
         String(selectedMedia.count),
         // Picking the Poll/Event/Sell tab on a new, empty post loses nothing,
         // so the type only counts once a saved post or draft is open.
         isEditMode || draftId != nil ? postType.rawValue : "",
         communityAudience.rawValue,
         scheduleAt.map { String($0.timeIntervalSince1970) } ?? "",
         // The Poll tab adds blank option rows; only typed options count.
         composerViewModel.pollOptions.map { $0.trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }.joined(separator: "|"),
         composerViewModel.eventTitle, composerViewModel.eventLocation,
         composerViewModel.jobTitle, composerViewModel.jobCareersUrl]
    }
    @State private var openedSignature: [String]?
    /// Cancel only asks when something changed since the screen opened.
    private var hasChanges: Bool { openedSignature.map { $0 != editSignature } ?? false }

    /// The other drafts for the same place. The feed, or this community
    /// (not the one already open).
    private var feedDrafts: [Post] { drafts.drafts(inCommunity: community?.id).filter { $0.id != draftId } }

    /// Edit mode only: does the post being edited ALREADY have media or a link that
    /// hasn't been changed? `selectedMedia`/`linkPreview` only ever reflect NEWLY
    /// picked media/a newly-detected link in this view. Edit mode never seeds them
    /// from the existing post (images stay server-side, referenced by URL, until the
    /// user picks new ones), so without this a caption-less media/link post being
    /// edited would look content-less and Save would be wrongly disabled forever.
    private var editingPostHasExistingMediaOrLink: Bool {
        guard isEditMode else { return false }
        return !(editingPost?.displayImageUrls.isEmpty ?? true) || editingPost?.linkUrl != nil
    }

    private var isPostDisabled: Bool {
        // Poll/event validity (min 2 options, event title + future start time)
        // is delegated to composerViewModel.isValid. Same rule the Community
        // composer already enforces for identical post types.
        guard postType == .text else {
            // Photos are picked through this screen's model, so wait for them too.
            return !composerViewModel.isValid || composerViewModel.isPosting || viewModel.pendingMediaCount > 0
        }
        // Allow posting when there's text OR media/link (an image/video/link-only post
        // doesn't need a caption). In edit mode, media/link the post already has also
        // counts, not just newly picked media or a newly detected link.
        let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedMedia.isEmpty
            || viewModel.linkPreview != nil
            || editingPostHasExistingMediaOrLink
        // Picked media still loading would be left out of the post, so wait
        // until every item is in.
        return !hasContent || isPosting || viewModel.pendingMediaCount > 0
            || content.count > composerViewModel.maxLength
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
                                    .scaledFont(16, .bold)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))

                                if let target {
                                    communityChip(target)
                                } else {
                                    Button { showPrivacyPicker = true } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: privacy.icon)
                                                .scaledFont(11, .semibold)
                                            Text(privacy.label(for: appState.currentMode))
                                                .scaledFont(13, .semibold)
                                            Image(systemName: "chevron.down")
                                                .scaledFont(9, .bold)
                                        }
                                        .foregroundColor(themeManager.theme.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(themeManager.theme.softFill))
                                    }
                                    .buttonStyle(.plain)
                                    if canCrossPost {
                                        Toggle(bundle.loc("Post in Hobby and Work"), isOn: $postInBothModes)
                                            .scaledFont(13, .semibold)
                                            .tint(themeManager.theme.primary)
                                            .fixedSize()
                                    }
                                }
                            }

                            Spacer()

                            // Mode badge (icon only). Hobby vs work,
                            // kept fully separate from the privacy icon to avoid confusion.
                            Image(systemName: effectiveMode.glyph)
                                .scaledFont(15, .semibold)
                                .foregroundColor(themeManager.theme.primary)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(themeManager.theme.softFill))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // ── Post type picker (create mode only. Editing an
                        // existing post never changes its type) ────────────────
                        if !isEditMode {
                            Picker("Post type", selection: $postType) {
                                Text("Text", bundle: bundle).tag(PostType.text)
                                Text("Poll", bundle: bundle).tag(PostType.poll)
                                Text("Event", bundle: bundle).tag(PostType.event)
                                // Job posts are Work-mode only and only for a
                                // verified HR (both enforced server-side too,
                                // see PostService.createJobPost).
                                if effectiveMode == .work && appState.hrCompany != nil {
                                    Text("Job", bundle: bundle).tag(PostType.job)
                                }
                                // In a community: sell an item there straight away.
                                if community != nil {
                                    Text("Sell", bundle: bundle).tag(PostType.listing)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .onChange(of: postType) { old, new in
                                // "Sell" opens the Sell form; the composer stays on its tab.
                                if new == .listing {
                                    postType = old
                                    if onSell != nil {
                                        // Typed text gets the usual save-or-discard question first.
                                        if hasChanges {
                                            leavingForSell = true
                                            showLeaveDialog = true
                                        } else {
                                            leaveForSell()
                                        }
                                    } else {
                                        showSell = true
                                    }
                                } else {
                                    composerViewModel.postType = new
                                }
                            }
                        }

                        // Work text post looking for a job: verified HRs can answer
                        // it with one of their jobs (server migration 132).
                        if postType == .text && effectiveMode == .work && community == nil && !isEditMode {
                            Toggle(isOn: $composerViewModel.openToWork) {
                                HStack(spacing: 6) {
                                    Image(systemName: "briefcase.fill").foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Open to work", bundle: bundle).scaledFont(15, .semibold)
                                        Text("Verified HRs can reply with one of their jobs.", bundle: bundle)
                                            .scaledFont(12).foregroundColor(AppColors.textSecondary(colorScheme))
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                        }

                        // ── Row 2: Text box ────────────────────────────────────
                        // Same size and line width as the text in a post card (15pt body,
                        // 8pt card margin + 12pt padding, so 20pt in from the screen edge
                        // with the editor's own 5pt inset), so it wraps exactly like the post.
                        MarkdownTextEditor(text: $content, placeholder: placeholderText,
                                           size: AppFont.body.spec.size,
                                           minHeight: 150, maxHeight: 360)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(AppColors.surface(colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                )
                        )
                        .overlay(alignment: .bottomTrailing) {
                            // The server caps posts at this length.
                            let remaining = composerViewModel.maxLength - content.count
                            Text("\(remaining)")
                                .scaledFont(12)
                                .foregroundColor(remaining < 50 ? AppColors.danger(colorScheme) : AppColors.textTertiary(colorScheme))
                                .padding(10)
                        }
                        .padding(.horizontal, 8)

                        // ── Poll/Event/Job inline sections, @Binding-only
                        // components, already post-type-agnostic. ────────────
                        if postType == .poll {
                            CreatePollSheet(
                                options:     $composerViewModel.pollOptions,
                                endsAt:      $composerViewModel.pollEndsAt,
                                showEndDate: $composerViewModel.showPollEndDate
                            )
                            // Same inset as the text box above, so the edges line up.
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                        } else if postType == .event {
                            CreateEventSheet(
                                title:       $composerViewModel.eventTitle,
                                location:    $composerViewModel.eventLocation,
                                startsAt:    $composerViewModel.eventStartsAt,
                                endsAt:      $composerViewModel.eventEndsAt,
                                showEndDate: $composerViewModel.showEventEndDate
                            )
                            // Same inset as the text box above, so the edges line up.
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                        } else if postType == .job {
                            CreateJobSheet(
                                title:                    $composerViewModel.jobTitle,
                                employmentType:           $composerViewModel.jobEmploymentType,
                                salaryRange:              $composerViewModel.jobSalaryRange,
                                applicationDeadline:      $composerViewModel.jobApplicationDeadline,
                                showApplicationDeadline:  $composerViewModel.showJobApplicationDeadline,
                                details: composerViewModel
                            )
                            // Same inset as the text box above, so the edges line up.
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                        }

                        // ── Media preview (text posts) ───────────────────────
                        if takesMedia && (!selectedMedia.isEmpty || viewModel.pendingMediaCount > 0) {
                            mediaPreview
                                .padding(.horizontal, 16)
                        }

                        if postType == .text {
                            // ── Link preview card ────────────────────────────
                            if viewModel.isFetchingLink {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("Loading link preview...", bundle: bundle)
                                        .scaledFont(13)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                                .padding(.horizontal, 16)
                            } else if let preview = viewModel.linkPreview {
                                linkPreviewCard(preview)
                                    .padding(.horizontal, 16)
                            }
                        }

                        // ── Hashtags found in the text ───────────────────────────
                        if !hashtags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: AppSpacing.sm) {
                                    ForEach(hashtags, id: \.self) { tag in
                                        HStack(spacing: 6) {
                                            Text("#\(tag)")
                                            if typedTags.contains(tag) {
                                                Button { typedTags.removeAll { $0 == tag } } label: {
                                                    Image(systemName: "xmark").scaledFont(10, .bold)
                                                }
                                                .accessibilityLabel(bundle.loc("Remove hashtag"))
                                            }
                                        }
                                        .scaledFont(14)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Capsule().fill(AppColors.surface(colorScheme)))
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // ── Photo/Video button (text posts. The only type the
                        // backend takes image_urls on here) ───────────────────
                        if takesMedia {
                            PhotosPicker(
                                selection: $selectedItems,
                                maxSelectionCount: 10,
                                matching: .any(of: [.images, .videos])
                            ) {
                                HStack(spacing: 8) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .scaledFont(16, .medium)
                                        .foregroundColor(Color(hex: "#45BD62"))
                                    Text("Photo / Video", bundle: bundle)
                                        .scaledFont(15, .medium)
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
                            .disabled(photosBlockedByLink)
                            .opacity(photosBlockedByLink ? 0.45 : 1)
                            .padding(.horizontal, 16)
                            .padding(.bottom, photosBlockedByLink ? 0 : 8)

                            if photosBlockedByLink {
                                Text("Photos can't be added to a post with a link. Remove the link to attach photos.", bundle: bundle)
                                    .scaledFont(13)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 8)
                            }
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
                                    .scaledFont(18, .medium)
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
                        if isPosting {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8).tint(.white)
                                Text("Posting...", bundle: bundle)
                                    .scaledFont(15, .semibold)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(AppColors.textTertiary(colorScheme)))
                        } else {
                            Text(isEditMode ? bundle.loc("Save") : bundle.loc(scheduleAt == nil ? "Post" : "Schedule"))
                                .scaledFont(15, .bold)
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
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Nothing changed → nothing to lose, so no question.
                    Button(bundle.loc("Cancel")) {
                        if hasChanges { showLeaveDialog = true } else { dismiss() }
                    }
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .confirmationDialog(bundle.loc(isEditMode ? "Discard changes?"
                                                   : draftId == nil ? "Save this post as a draft?" : "Save your changes to this draft?"),
                                        isPresented: $showLeaveDialog, titleVisibility: .visible) {
                        // A draft is a new post's safety net; editing a posted one has none.
                        if !isEditMode && !isPostDisabled {
                            Button(bundle.loc("Save draft")) {
                                // savePost closes the composer once the draft is saved.
                                if leavingForSell { onSell?() }
                                savePost(as: .draft)
                            }
                        }
                        Button(bundle.loc(draftId == nil ? "Discard" : "Discard changes"), role: .destructive) {
                            if leavingForSell { leaveForSell() } else { dismiss() }
                        }
                        Button(bundle.loc("Keep editing"), role: .cancel) { leavingForSell = false }
                    }
                }
                if !isEditMode && !feedDrafts.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(String(format: bundle.loc("Drafts (%lld)"), feedDrafts.count)) { showDraftPicker = true }
                            .foregroundColor(themeManager.theme.primary)
                    }
                }
            }
            .sheet(isPresented: $showSell) {
                if let community {
                    // Listed in this community (already ticked in step 2) and the Marketplace.
                    CreateListingView(mode: effectiveMode, preselectedCommunityId: community.id) { listing in
                        if listing.publishStatus != "pending" { onPostCreated?(listing) }
                        showSell = false
                        dismiss()
                    }
                    .environment(appState)
                    .environment(themeManager)
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
                if initialPostType == .job, postType == .text, editingPost == nil, draft == nil,
                   effectiveMode == .work, appState.hrCompany != nil {
                    postType = .job
                }
                if let draft, draftId == nil { loadDraft(draft) }
                if let post = editingPost {
                    content = post.content
                    typedTags = post.tags
                    privacy = post.privacy
                    communityAudience = post.community?.audience ?? .members
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
                openedSignature = editSignature
            }
            .onChange(of: content) { _, newContent in
                // Keep composerViewModel.content mirrored regardless of
                // postType, it's the single field composerViewModel.isValid
                // (poll/event validation) and submitPoll/submitEvent both read.
                composerViewModel.content = newContent
                if suppressNextLinkDetect {
                    suppressNextLinkDetect = false
                    return
                }
                let split = PostText.extractingFinishedTags(from: newContent)
                if !split.tags.isEmpty {
                    for t in split.tags where !typedTags.contains(where: { $0.lowercased() == t.lowercased() }) { typedTags.append(t) }
                    content = split.text
                    return
                }
                if postType == .text {
                    viewModel.detectAndFetchLink(newContent) {
                        // The card now carries the link; keep it out of the text.
                        content = PostText.removingLinks(from: content)
                    }
                }
            }
            .sheet(isPresented: $showPrivacyPicker) {
                PrivacyPickerSheet(selected: $privacy, mode: appState.currentMode)
            }
            // Upload or post failure. The composer stays open with everything
            // intact so the user can retry or remove the media. Either view
            // model can fail: feed text posts use one, everything else the other.
            .alert(
                bundle.loc("Couldn't post"),
                isPresented: Binding(
                    get: { (viewModel.errorMessage ?? composerViewModel.errorMessage) != nil },
                    set: { if !$0 { viewModel.errorMessage = nil; composerViewModel.errorMessage = nil } }
                )
            ) {
                Button(bundle.loc("OK"), role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? composerViewModel.errorMessage ?? "")
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
    /// Hands over to the presenter, which opens New listing once this closes.
    private func leaveForSell() {
        onSell?()
        dismiss()
    }

    private func savePost(as publish: PublishChoice) {
        moveTagsOutOfText()
        // `held`: saved but waiting for review (a new HR's job), so not in any feed yet.
        let finish: (Post, Bool) -> Void = { post, held in
            if publish.isLive && !held {
                // Broadcast beyond just this composer's own caller. E.g.
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
            confirmSaved(publish, awaitingApproval: held)
            dismiss()
        }
        if let community {
            submitToCommunity(community, publish: publish)
        } else if postType == .text {
            viewModel.submitPost(
                content: content,
                mode: appState.currentMode,
                privacy: privacy,
                authToken: appState.authToken,
                selectedMedia: selectedMedia,
                hashtags: hashtags,
                publish: publish,
                replacesDraft: draftId,
                alsoOtherMode: canCrossPost && postInBothModes,
                onSuccess: { finish($0, false) }
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
                ) { communityPost in
                    finish(feedPost(from: communityPost), communityPost.publishStatus == "pending")
                }
            }
        }
    }

    /// What happened to the post, as a toast at the bottom edge: it doesn't
    /// interrupt like an alert, and it stays on screen after the composer closes.
    private func confirmSaved(_ publish: PublishChoice, awaitingApproval: Bool) {
        let message: String
        switch publish {
        case .now where awaitingApproval && postType == .job:
            message = bundle.loc("Sent for review. ConnectSphere checks a new HR's first jobs before they go live.")
        case .now where awaitingApproval:
            message = bundle.loc("Your post is waiting for approval. An admin or moderator will review it.")
        case .now:
            message = bundle.loc("Your post is now published.")
        case .schedule(let at):
            message = String(format: bundle.loc("Your post is scheduled for %@"),
                             at.formatted(date: .abbreviated, time: .shortened))
        case .draft:
            message = bundle.loc("Saved to drafts.")
        }
        toast.show(message: message)
    }

    /// Only the official account cross-posts, and only a text post on its own
    /// feed (a community post belongs to that community's mode).
    private var canCrossPost: Bool {
        (appState.currentUser?.isOfficial ?? false) && target == nil && postType == .text
    }

    /// A community takes every post type through its own endpoint, text
    /// included, so the text post's media and link go to the composer
    /// model too. The server makes it public and applies post approval.
    private func submitToCommunity(_ community: Community, publish: PublishChoice) {
        let mode = effectiveMode
        composerViewModel.postType = postType
        composerViewModel.content = content
        composerViewModel.selectedMedia = selectedMedia
        composerViewModel.linkPreview = viewModel.linkPreview
        composerViewModel.publish = publish
        composerViewModel.replacesDraftId = draftId
        composerViewModel.communityAudience = community.privacy == .private ? .members : communityAudience
        let replaced = draftId
        Task<Void, Never>(name: nil) {
            await composerViewModel.submitPost(
                communityId: community.id,
                token: appState.authToken ?? "",
                mode: mode,
                privacy: .publicAll,
                hashtags: hashtags
            ) { communityPost in
                // A held post (a new HR's job under review) isn't in the feed yet.
                if publish.isLive && communityPost.publishStatus != "pending" {
                    onPostCreated?(communityPost.toPost(
                        author: appState.currentUser ?? MockData.currentUser,
                        mode: mode, privacy: .publicAll
                    ))
                }
                if !publish.isLive || replaced != nil {
                    NotificationCenter.default.post(name: .draftsChanged, object: nil)
                }
                confirmSaved(publish, awaitingApproval: communityPost.publishStatus == "pending")
                dismiss()
            }
        }
    }

    private var placeholderText: String {
        guard community != nil else {
            return effectiveMode == .hobby
                ? bundle.loc("What's on your mind?")
                : bundle.loc("Share a professional update...")
        }
        switch postType {
        case .text:  return bundle.loc("Share something with the community…")
        case .poll:  return bundle.loc("What do you want to ask?")
        case .event: return bundle.loc("Describe this event…")
        case .job:   return bundle.loc("Describe this role…")
        case .listing, .legit: return bundle.loc("Describe what you're selling…")
        }
    }

    /// The text is final: a tag still sitting in it (typed last, no space after)
    /// becomes a chip too, so no `#word` is left inside the saved text.
    private func moveTagsOutOfText() {
        let tags = hashtags
        let cleaned = PostText.extractingFinishedTags(from: content, includingTrailing: true).text
        typedTags = tags
        if cleaned != content {
            content = cleaned
            composerViewModel.content = cleaned
        }
    }

    /// Fills the composer from a saved draft.
    private func loadDraft(_ d: Post) {
        draftId = d.id
        suppressNextLinkDetect = d.linkUrl != nil
        content = d.content
        typedTags = d.tags
        privacy = d.privacy
        postType = d.postType
        selectedItems = []
        selectedMedia = PickedPostMedia.remote(d.imageUrls, alts: d.imageAlts)
        viewModel.linkPreview = d.linkUrl.map {
            LinkPreviewDTO(url: $0, title: d.articleTitle ?? $0, description: nil, image: d.imageUrl, siteName: nil)
        }
        composerViewModel.load(d)
        scheduleAt = d.publishStatus == "scheduled" ? d.publishAt : nil
        openedSignature = editSignature
    }

    /// Adapts a `CommunityPost` (what PostComposerViewModel's shared submit
    /// path returns) into a Feed `Post` for this screen's Post-typed
    /// callbacks. mode/privacy come from local composer state (already known
    ///, this IS what was just submitted), not decoded from the response.
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

    /// Where it goes, then who can see it, "Community only ▾" / "Public ▾".
    /// A private community's posts are members-only, so there's no choice.
    private func communityChip(_ target: (name: String, icon: String, isPrivate: Bool)) -> some View {
        let audience: CommunityAudience = target.isPrivate ? .members : communityAudience
        return VStack(alignment: .leading, spacing: 6) {
            chip {
                Text(target.icon).scaledFont(12)
                Text(target.name)
                    .scaledFont(13, .semibold)
                    .lineLimit(1)
            }
            .accessibilityLabel(Text(String(format: bundle.loc("Post to %@"), target.name)))

            if target.isPrivate {
                chip { audienceLabel(audience) }
                    .accessibilityLabel(Text(bundle.loc("Only members of a private community can see its posts")))
            } else {
                Menu {
                    Picker(bundle.loc("Who can see this post"), selection: $communityAudience) {
                        Label(bundle.loc("Community only"), systemImage: CommunityAudience.members.icon)
                            .tag(CommunityAudience.members)
                        Label(bundle.loc("Public"), systemImage: CommunityAudience.publicAll.icon)
                            .tag(CommunityAudience.publicAll)
                    }
                } label: {
                    chip {
                        audienceLabel(audience)
                        Image(systemName: "chevron.down").scaledFont(9, .bold)
                    }
                }
                .accessibilityLabel(Text(bundle.loc("Who can see this post")))
            }
        }
    }

    private func audienceLabel(_ audience: CommunityAudience) -> some View {
        HStack(spacing: 5) {
            Image(systemName: audience.icon).scaledFont(11, .semibold)
            Text(bundle.loc(audience.label)).scaledFont(13, .semibold)
        }
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .foregroundColor(themeManager.theme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(themeManager.theme.softFill))
    }

    private func saveEdit() {
        guard let post = editingPost else { return }
        moveTagsOutOfText()
        viewModel.updatePost(
            postId: post.id,
            content: content,
            privacy: privacy,
            selectedMedia: selectedMedia,
            existingImageUrls: post.displayImageUrls,
            communityAudience: post.community == nil ? nil : communityAudience,
            hashtags: hashtags
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
                        .scaledFont(10, .semibold)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(preview.title)
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                if let desc = preview.description {
                    Text(desc)
                        .scaledFont(12)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { viewModel.linkPreview = nil } label: {
                Image(systemName: "xmark")
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(10)
            }
            .accessibilityLabel(Bundle.app.loc("Remove link preview"))
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
                                    .scaledFont(30)
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
                                .scaledFont(22)
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .accessibilityLabel(Bundle.app.loc("Remove photo"))
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
