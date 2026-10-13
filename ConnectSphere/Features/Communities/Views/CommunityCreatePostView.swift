import SwiftUI
import PhotosUI

struct CommunityCreatePostView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle
    /// The picked photo/video whose alt text is being written.
    @State private var altTarget: PickedPostMedia?
    @State private var viewModel = PostComposerViewModel()

    // Hashtags — same field/caps as Feed's CreatePostView, reusing the shared
    // HashtagInputView unmodified.
    @State private var hashtags: [String] = []
    @State private var hashtagController = HashtagInputController()

    let community: Community
    /// Opens the composer on one of this community's saved drafts.
    var draft: Post? = nil
    let onPostCreated: (Post) -> Void

    @State private var drafts = DraftsViewModel()
    @State private var showLeaveDialog = false
    @State private var showDraftPicker = false
    @State private var scheduleAt: Date?
    @State private var showSchedulePicker = false

    /// This community's other drafts (not the one already open).
    private var communityDrafts: [Post] {
        drafts.drafts(inCommunity: community.id).filter { $0.id != viewModel.replacesDraftId }
    }

    /// Anything typed or attached — closing would lose it, so ask first.
    private var hasUnsavedWork: Bool {
        !viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !viewModel.selectedMedia.isEmpty || viewModel.linkPreview != nil
    }

    private func loadDraft(_ d: Post) {
        viewModel.load(d)
        hashtags = d.tags
        scheduleAt = d.publishStatus == "scheduled" ? d.publishAt : nil
    }

    /// Posts now, or saves a draft (replacing the one it was opened from).
    private func savePost(as publish: PublishChoice) {
        // Flush whatever's still typed-but-uncommitted in the hashtag field
        // before reading `hashtags` — otherwise a hashtag typed right before
        // tapping Post (no space/return/suggestion tap) is silently dropped.
        hashtagController.commitPending(into: &hashtags)
        let replaced = viewModel.replacesDraftId
        viewModel.publish = publish
        Task<Void, Never>(name: nil) {
            // mode/privacy here match exactly what the backend's own COALESCE
            // fallback would have derived when these params were omitted
            // (community.type -> hobby/work, privacy always 'public').
            let mode: AppMode = community.type == .work ? .work : .hobby
            await viewModel.submitPost(
                communityId: community.id,
                token: appState.authToken ?? "",
                mode: mode,
                privacy: .publicAll,
                hashtags: hashtags
            ) { communityPost in
                if publish.isLive {
                    onPostCreated(communityPost.toPost(
                        author: appState.currentUser ?? MockData.currentUser,
                        mode: mode, privacy: .publicAll
                    ))
                }
                if !publish.isLive || replaced != nil {
                    NotificationCenter.default.post(name: .draftsChanged, object: nil)
                }
                dismiss()
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Community tag chip
                    HStack(spacing: 6) {
                        Text(community.iconEmoji)
                        Text(String(format: bundle.loc("Post to %@"), community.name))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppColors.elevated(colorScheme))

                    // Post type picker
                    Picker("Post type", selection: $viewModel.postType) {
                        Text("Text", bundle: bundle).tag(PostType.text)
                        Text("Poll", bundle: bundle).tag(PostType.poll)
                        Text("Event", bundle: bundle).tag(PostType.event)
                        // Job posts are a Work-mode-only concept — hidden from
                        // the picker in a non-Work community (also enforced
                        // server-side, see PostService.createJobPost).
                        if community.type == .work {
                            Text("Job", bundle: bundle).tag(PostType.job)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if viewModel.content.isEmpty {
                            Text(placeholderText)
                                .font(.system(size: 16))
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                        }
                        TextEditor(text: $viewModel.content)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .frame(minHeight: 140)
                            .onChange(of: viewModel.content) { _, new in
                                if new.count > viewModel.maxLength {
                                    viewModel.content = String(new.prefix(viewModel.maxLength))
                                }
                                viewModel.detectAndFetchLink(viewModel.content)
                            }
                    }
                    .appBackground()

                    // ── Media preview (text posts only — parity with Feed) ──
                    if viewModel.postType == .text, !viewModel.selectedMedia.isEmpty || viewModel.pendingMediaCount > 0 {
                        mediaPreview
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    // ── Link preview card ────────────────────────────────
                    if viewModel.postType == .text {
                        if viewModel.isFetchingLink {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading link preview...", bundle: bundle)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        } else if let preview = viewModel.linkPreview {
                            linkPreviewCard(preview)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }
                    }

                    // ── Photo/Video button (text posts only — backend only
                    // accepts image_urls on post_type='text') ─────────────
                    if viewModel.postType == .text {
                        PhotosPicker(
                            selection: $viewModel.selectedItems,
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
                        .onChange(of: viewModel.selectedItems) { _, items in
                            Task { await viewModel.loadSelectedMedia(items) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    // ── Hashtags — applies to all post types ──
                    HashtagInputView(hashtags: $hashtags, controller: hashtagController)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    Divider().background(AppColors.borderDefault(colorScheme))

                    // Character count
                    HStack {
                        Spacer()
                        Text("\(viewModel.remaining)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(viewModel.remaining < 50
                                ? .red
                                : AppColors.textTertiary(colorScheme))
                            .padding(.trailing, 16)
                            .padding(.vertical, 8)
                    }

                    Divider().background(AppColors.borderSubtle(colorScheme))

                    // Type-specific input sections
                    switch viewModel.postType {
                    case .poll:
                        CreatePollSheet(
                            options:     $viewModel.pollOptions,
                            endsAt:      $viewModel.pollEndsAt,
                            showEndDate: $viewModel.showPollEndDate
                        )
                    case .event:
                        CreateEventSheet(
                            title:       $viewModel.eventTitle,
                            location:    $viewModel.eventLocation,
                            startsAt:    $viewModel.eventStartsAt,
                            endsAt:      $viewModel.eventEndsAt,
                            showEndDate: $viewModel.showEventEndDate
                        )
                    case .job:
                        CreateJobSheet(
                            title:                   $viewModel.jobTitle,
                            company:                 $viewModel.jobCompany,
                            location:                $viewModel.jobLocation,
                            employmentType:          $viewModel.jobEmploymentType,
                            salaryRange:             $viewModel.jobSalaryRange,
                            applicationDeadline:     $viewModel.jobApplicationDeadline,
                            showApplicationDeadline: $viewModel.showJobApplicationDeadline
                        )
                    case .text:
                        EmptyView()
                    }

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationTitle(bundle.loc("New post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) {
                        if hasUnsavedWork { showLeaveDialog = true } else { dismiss() }
                    }
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .confirmationDialog(bundle.loc(viewModel.replacesDraftId == nil ? "Save this post as a draft?" : "Save your changes to this draft?"),
                                        isPresented: $showLeaveDialog, titleVisibility: .visible) {
                        if viewModel.isValid {
                            Button(bundle.loc("Save draft")) { savePost(as: .draft) }
                        }
                        Button(bundle.loc(viewModel.replacesDraftId == nil ? "Discard" : "Discard changes"), role: .destructive) { dismiss() }
                        Button(bundle.loc("Keep editing"), role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc(scheduleAt == nil ? "Post" : "Schedule")) {
                        savePost(as: scheduleAt.map(PublishChoice.schedule) ?? .now)
                    }
                        .font(.system(size: 15, weight: .bold))
                        .disabled(!viewModel.isValid || viewModel.isPosting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSchedulePicker = true } label: { Image(systemName: scheduleAt == nil ? "clock" : "clock.fill") }
                        .accessibilityLabel(Text("Schedule post", bundle: bundle))
                }
                if !communityDrafts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(format: bundle.loc("Drafts (%lld)"), communityDrafts.count)) { showDraftPicker = true }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let scheduleAt {
                    ScheduleLine(date: scheduleAt, onEdit: { showSchedulePicker = true },
                                 onClear: { self.scheduleAt = nil })
                        .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: $showSchedulePicker) {
                SchedulePickerSheet(initial: scheduleAt) { scheduleAt = $0 }
            }
            .sheet(isPresented: $showDraftPicker) {
                DraftPickerSheet(drafts: communityDrafts) { picked in loadDraft(picked) }
            }
            .task { await drafts.load() }
            .onAppear {
                if let draft, viewModel.replacesDraftId == nil { loadDraft(draft) }
            }
        }
    }

    private var placeholderText: String {
        switch viewModel.postType {
        case .text:  return bundle.loc("Share something with the community…")
        case .poll:  return bundle.loc("What do you want to ask?")
        case .event: return bundle.loc("Describe this event…")
        case .job:   return bundle.loc("Describe this role…")
        }
    }

    // MARK: - Media preview

    /// Same layout as Feed's CreatePostView.mediaPreview so a community
    /// composer looks identical while picking photos/videos.
    /// One item fills the row; several share it as squares. Loading tiles
    /// count too, so the row doesn't jump when they turn into the media.
    private var tileSize: CGSize {
        viewModel.selectedMedia.count + viewModel.pendingMediaCount == 1 ? CGSize(width: 280, height: 200) : CGSize(width: 160, height: 160)
    }

    private var mediaPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.selectedMedia) { media in
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
                            viewModel.selectedMedia.removeAll { $0.id == media.id }
                            if let item = media.pickerItem { viewModel.selectedItems.removeAll { $0 == item } }
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
                if let index = viewModel.selectedMedia.firstIndex(where: { $0.id == media.id }) { viewModel.selectedMedia[index].altText = text }
            }
        }
    }

    // MARK: - Link preview

    /// Same layout as Feed's CreatePostView.linkPreviewCard.
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
}
