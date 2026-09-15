import SwiftUI

struct PostCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(UndoToastPresenter.self) var toastPresenter
    @Environment(\.openURL) private var openURL
    @State private var isLiked:      Bool
    @State private var isSaved:      Bool
    @State private var likeCount:    Int
    @State private var commentCount: Int
    @State private var shareCount:   Int
    @State private var showComments  = false
    @State private var showShareSheet = false

    // Action states
    @State private var showDeleteAlert = false
    @State private var showEditSheet   = false
    @State private var isHidden        = false   // locally hides someone else's post
    @State private var showReportDialog  = false
    @State private var showReportResult  = false
    @State private var reportResultMessage = ""

    var post: Post
    var disableSelfNavigation: Bool = false
    var onOwnAvatarTapped: (() -> Void)? = nil
    var onCommentAdded: (() -> Void)? = nil
    /// Called when the user successfully deletes their own post
    var onPostDeleted: (() -> Void)? = nil
    /// Called when the user successfully saves an edit to the post
    var onPostUpdated: ((Post) -> Void)? = nil
    /// When set, tapping anywhere on the card (outside its own controls) opens
    /// it in a pushed `PostDetailView`, and the comment button opens it there
    /// with the composer focused (`focusComposer == true`). `nil` = no
    /// whole-card tap (e.g. inside `PostDetailView` itself, so it can't recurse).
    var onOpenDetail: ((_ focusComposer: Bool) -> Void)? = nil
    /// Corner radius for the card's own clip shape. Default `12` everywhere;
    /// `PostDetailView` passes `0` so its embedded copy reads as a square-edged
    /// panel pinned at the top of the screen rather than a floating card.
    var cornerRadius: CGFloat = 12
    /// When set, the whole card (header + content + action row) is capped at
    /// most to this total height *only while its content actually needs more
    /// room than that* — the header and action row always render in full;
    /// the content region (text/tags/media/poll/event) renders at its true
    /// natural height when that already fits the budget (a short post is
    /// never stretched to fill it), and only clips — with an "Expand" button
    /// overlaid at its bottom-right — once it genuinely overflows. Tapping it
    /// (or the "Collapse" button that replaces it once expanded) toggles a
    /// bounded, scrollable full view capped at `expandedTotalHeight`. `nil`
    /// (every host except `PostDetailView`) = always full height, no clipping.
    var collapsedTotalHeight: CGFloat? = nil
    /// Total on-screen height cap for the expanded state (same "whole card"
    /// budget `collapsedTotalHeight` is), used only once `isContentExpanded`.
    /// `nil` falls back to `collapsedTotalHeight * 2`.
    var expandedTotalHeight: CGFloat? = nil

    @State private var shakeAmount: CGFloat = 0
    @State private var isContentExpanded = false
    // Seeded with realistic estimates so the very first render (before the
    // real measurements land via readHeight) doesn't briefly show too much
    // content and then visibly snap down a frame later.
    @State private var measuredHeaderHeight: CGFloat = 64
    @State private var measuredActionsHeight: CGFloat = 54
    /// The content region's true natural height, kept live via `readHeight`
    /// while it fits the budget; `nil` until first measured.
    @State private var measuredContentHeight: CGFloat? = nil
    /// Drives the in-app browser (see `openLink(_:)`) for a tapped http(s)
    /// link — the link-preview card or an in-text URL.
    @State private var inAppBrowserURL: URL?
    private let repository = PostRepository()

    init(
        post: Post,
        disableSelfNavigation: Bool = false,
        onOwnAvatarTapped: (() -> Void)? = nil,
        onCommentAdded: (() -> Void)? = nil,
        onPostDeleted: (() -> Void)? = nil,
        onPostUpdated: ((Post) -> Void)? = nil,
        onOpenDetail: ((_ focusComposer: Bool) -> Void)? = nil,
        cornerRadius: CGFloat = 12,
        collapsedTotalHeight: CGFloat? = nil,
        expandedTotalHeight: CGFloat? = nil
    ) {
        self.post = post
        self.disableSelfNavigation = disableSelfNavigation
        self.onOwnAvatarTapped = onOwnAvatarTapped
        self.onCommentAdded = onCommentAdded
        self.onPostDeleted = onPostDeleted
        self.onPostUpdated = onPostUpdated
        self.onOpenDetail = onOpenDetail
        self.cornerRadius = cornerRadius
        self.collapsedTotalHeight = collapsedTotalHeight
        self.expandedTotalHeight = expandedTotalHeight
        _isLiked      = State(initialValue: post.isLiked)
        _isSaved      = State(initialValue: post.isSaved)
        _likeCount    = State(initialValue: post.likeCount)
        _commentCount = State(initialValue: post.commentCount)
        _shareCount   = State(initialValue: post.shareCount)
    }

    @ViewBuilder
    var body: some View {
        if !isHidden {
            mainCard
        }
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            postHeader
                .readHeight { measuredHeaderHeight = $0 }
            collapsibleBody
            Divider().padding(.horizontal, 12).padding(.top, 8)
            actionButtons
                .readHeight { measuredActionsHeight = $0 }
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .offset(x: shakeAmount)
        // Whole-card tap-to-open — placed on the outer container so it covers
        // header/body/action-row dead space uniformly; every interactive child
        // (avatar/name links, the "…" menu, tag chips, the link-preview card,
        // poll/event controls, the like/comment/save/share buttons) still wins
        // its own tap over this parent gesture, so nothing here regresses.
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail?(false) }
        // In-app browser for tapped links (link-preview card, in-text URLs)
        .inAppBrowser(url: $inAppBrowserURL)
        // Comment sheet
        .sheet(isPresented: $showComments) {
            CommentSheet(postId: post.id, postAuthorId: post.author.id) { delta in
                commentCount = max(0, commentCount + delta)
                if delta > 0 { onCommentAdded?() }
            }
            .environment(appState)
        }
        // Edit sheet — reuses CreatePostView with editingPost
        .sheet(isPresented: $showEditSheet) {
            CreatePostView(editingPost: post, onPostUpdated: { updatedPost in
                onPostUpdated?(updatedPost)
            })
            .environment(appState)
            .environment(themeManager)
        }
        // Share sheet
        .sheet(isPresented: $showShareSheet) {
            SharePostSheet(post: post) {
                shareCount += 1
            }
            .environment(appState)
            .environment(themeManager)
        }
        // Delete confirmation alert
        .alert(bundle.loc("Delete post?"), isPresented: $showDeleteAlert) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await handleDeletePost() }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This post won't be shown in the app. You can restore it from Recently Deleted within 30 days.", bundle: bundle)
        }
        // Report reason picker
        .confirmationDialog(
            bundle.loc("Why are you reporting this content?"),
            isPresented: $showReportDialog,
            titleVisibility: .visible
        ) {
            ForEach(ReportReason.allCases, id: \.self) { reason in
                Button(reason.displayName) {
                    Task { await handleReportPost(reason: reason) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        // Report result feedback
        .alert(reportResultMessage, isPresented: $showReportResult) {
            Button(bundle.loc("Done")) {}
        }
        // Resyncs the locally-tracked count whenever a fresh `post` value
        // flows in from the parent (e.g. after `.postUpdated` patches this
        // post's entry in FeedViewModel/ProfileViewModel following a comment
        // add/delete elsewhere) — `@State`'s `initialValue` only seeds once
        // per view identity, so without this the row would keep showing a
        // stale count until the app fully reloads it. Mirrors the same
        // pattern already used in `CommunityPostCard`.
        .onChange(of: post.commentCount) { _, newValue in commentCount = newValue }
    }

    // MARK: Body

    /// Everything between the header and the action row: text, hashtags, link
    /// preview / photos, shared-post embed, poll / event. The whole-card tap
    /// (see `mainCard`) covers this region too; the link-preview card, tag
    /// chips, and poll/event controls keep handling their own taps.
    @ViewBuilder
    private var postBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content — only shown if there's actual text
            if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(linkifiedContent)
                    .appFont(.body)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .tint(themeManager.theme.primary)
                    .environment(\.openURL, OpenURLAction { url in
                        openLink(url); return .handled
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Hashtag chips — tapping one opens TagFeedView to browse by tag
            if !post.tags.isEmpty {
                hashtagRow
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Link preview card (if there's a link_url)
            if let linkUrl = post.linkUrl, let url = URL(string: linkUrl) {
                linkPreviewCard(url: url)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            // Real uploaded images — Facebook-style grid, supports multiple images
            else if !post.displayImageUrls.isEmpty {
                PostPhotoGrid(urls: post.displayImageUrls)
                    .padding(.top, 10)
            }

            // Embedded original post (if this is a shared post)
            if post.sharedPostId != nil {
                sharedPostEmbed
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Poll or Event inline body — same PollPostCard/EventPostCard used by
            // CommunityPostCard, drop-in reusable since both view models are
            // fully post-id/event-id generic (no community coupling).
            switch post.postType {
            case .poll:
                if let pollData = post.pollData {
                    PollPostCard(
                        vm: PollViewModel(postId: post.id, pollData: pollData, token: appState.authToken ?? ""),
                        accentColor: themeManager.theme.primary
                    )
                    .padding(.top, 10)
                }
            case .event:
                if let eventData = post.eventData {
                    EventPostCard(
                        vm: EventViewModel(eventData: eventData, token: appState.authToken ?? ""),
                        accentColor: themeManager.theme.primary
                    )
                    .padding(.top, 10)
                }
            case .text:
                EmptyView()
            }
        }
    }

    // MARK: Collapsible body (PostDetailView's 1/4-height preview)

    /// A post with a link preview or uploaded photos/videos was already
    /// fully visible on the feed card that led here — always start it
    /// collapsed in `PostDetailView` (Expand still available) so the
    /// comments panel gets the space back by default, regardless of whether
    /// the media would technically fit the budget. Text-only posts are
    /// unaffected — they keep sizing to their natural height.
    private var hasMediaOrLinkContent: Bool {
        post.linkUrl != nil || !post.displayImageUrls.isEmpty
    }

    /// Wraps `postBody` with the collapse/expand treatment when
    /// `collapsedTotalHeight` is set; otherwise renders it untouched. The
    /// header and action row are never part of the clipped region — only the
    /// budget left over after their (measured) height is spent on content.
    /// A live (not one-way-locked) comparison: a post whose content already
    /// fits the budget is never stretched or clipped, and never shows the
    /// Expand button — only a post that genuinely overflows (or has media/a
    /// link, see `hasMediaOrLinkContent`) gets the clip + fade + button
    /// treatment.
    @ViewBuilder
    private var collapsibleBody: some View {
        if let totalBudget = collapsedTotalHeight {
            // Small fixed allowance for the Divider + its padding (~9pt) —
            // not worth measuring separately, it barely varies.
            let contentBudget = max(80, totalBudget - measuredHeaderHeight - measuredActionsHeight - 9)
            // nil = not measured yet → treat as "fits" so the very first
            // render never shows a spurious clip/Expand button before any
            // real measurement lands. A post with media/a link is always
            // forced to the collapsed branch regardless of measured height.
            let fits = !hasMediaOrLinkContent && (measuredContentHeight.map { $0 <= contentBudget } ?? true)

            if isContentExpanded {
                let expandedBudget = max(
                    contentBudget,
                    (expandedTotalHeight ?? totalBudget * 2) - measuredHeaderHeight - measuredActionsHeight - 9
                )
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        postBody
                    }
                    // Generous but still bounded — even a very long post stays
                    // scrollable within its own region instead of swallowing
                    // the whole screen (and pushing the comments panel away,
                    // which is exactly the problem this feature avoids).
                    .frame(height: min(expandedBudget, 480))
                    expandCollapseButton(systemImage: "chevron.up", label: "Collapse") {
                        withAnimation(.easeInOut(duration: 0.22)) { isContentExpanded = false }
                    }
                }
            } else if fits {
                // Content already fits the budget on its own — render it at
                // its true natural height (no frame, no clip, no button).
                // `readHeight` stays attached here (not in the `else` branch
                // below) so a post that grows past the budget — or is still
                // mid-measurement — keeps getting re-checked on every render.
                postBody
                    .readHeight { measuredContentHeight = $0 }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    postBody
                        .frame(height: contentBudget, alignment: .top)
                        .clipped()
                    // Fade so the hard clip at the bottom reads as "more below"
                    // rather than content getting cut off unintentionally —
                    // media (PostPhotoGrid tiles) already crop via
                    // `scaledToFill()`, so this looks consistent for a photo/
                    // video post too, not just truncated text.
                    LinearGradient(
                        colors: [AppColors.surface(colorScheme).opacity(0), AppColors.surface(colorScheme)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 44)
                    .allowsHitTesting(false)
                    expandCollapseButton(systemImage: "chevron.down", label: "Expand") {
                        withAnimation(.easeInOut(duration: 0.22)) { isContentExpanded = true }
                    }
                }
                .frame(height: contentBudget, alignment: .top)
            }
        } else {
            postBody
        }
    }

    private func expandCollapseButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label, bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(8)
    }

    // MARK: Report

    /// Submits a post report with the selected reason
    private func handleReportPost(reason: ReportReason) async {
        do {
            try await repository.reportPost(postId: post.id, reason: reason)
            reportResultMessage = bundle.loc("Report submitted")
        } catch {
            #if DEBUG
            print("[PostCard] reportPost error: \(error)")
            #endif
            reportResultMessage = bundle.loc("Could not submit report. Please try again.")
        }
        showReportResult = true
    }

    // MARK: Delete

    /// Calls the soft-delete API then notifies the parent feed to remove this card —
    /// while also showing an Undo toast, letting the user restore it within a few
    /// seconds before the post truly "disappears" from reach (it's still in Recently
    /// Deleted for 30 days).
    private func handleDeletePost() async {
        do {
            try await repository.deletePost(postId: post.id)
            NotificationCenter.default.post(name: .postDeleted, object: nil, userInfo: [
                "id": post.id,
                "authorId": post.author.id
            ])
            onPostDeleted?()

            let deletedPostId = post.id
            toastPresenter.show(message: bundle.loc("Post deleted")) {
                Task {
                    let restoreRepository = PostRepository()
                    if let restored = try? await restoreRepository.restorePost(postId: deletedPostId) {
                        NotificationCenter.default.post(name: .postRestored, object: nil, userInfo: [
                            "post": restored
                        ])
                    }
                }
            }
        } catch {
            #if DEBUG
            print("[PostCard] deletePost error: \(error)")
            #endif
        }
    }

    // MARK: Hide

    /// Hides someone else's post from your feed (persisted server-side so a
    /// reload doesn't bring it back) and shows an Undo toast — tapping Undo
    /// un-hides it in place. Unlike delete, the post is never removed from the
    /// feed's array, so flipping `isHidden` back to false fully restores the card.
    private func handleHidePost() {
        withAnimation { isHidden = true }
        Task { try? await repository.hidePost(postId: post.id) }

        let hiddenPostId = post.id
        toastPresenter.show(message: bundle.loc("Post hidden")) {
            withAnimation { isHidden = false }
            Task {
                let restoreRepository = PostRepository()
                try? await restoreRepository.unhidePost(postId: hiddenPostId)
            }
        }
    }

    // MARK: Shake

    private func triggerShake() {
        let step = 0.07
        withAnimation(.easeInOut(duration: step)) { shakeAmount = 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 1) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 2) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = 10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 3) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 4) {
            withAnimation(.easeInOut(duration: step)) { shakeAmount = 0 }
        }
    }

    // MARK: Linkified content

    private var linkifiedContent: AttributedString {
        var result = AttributedString(post.content)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: post.content, range: NSRange(post.content.startIndex..., in: post.content)) ?? []
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: post.content) else { continue }
            if let attrRange = Range(range, in: result) {
                result[attrRange].link = url
                result[attrRange].foregroundColor = themeManager.theme.primary
            }
        }
        return result
    }

    // MARK: Links

    /// http(s) → the in-app browser (matches Facebook/X/Instagram); anything
    /// else (`mailto:`, `tel:`, a custom app scheme) → the system opener,
    /// since `SFSafariViewController` can't handle those.
    private func openLink(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            inAppBrowserURL = url
        } else {
            openURL(url)
        }
    }

    // MARK: Link Preview Card

    private func linkPreviewCard(url: URL) -> some View {
        Button { openLink(url) } label: {
            VStack(spacing: 0) {
                // Thumbnail
                if let imageUrl = post.imageUrl.flatMap({ URL(string: $0) }) {
                    AsyncImage(url: imageUrl) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 180)
                                .clipped()
                        default:
                            Rectangle().fill(AppColors.base(colorScheme))
                                .frame(maxWidth: .infinity).frame(height: 100)
                        }
                    }
                }

                // Title + domain
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.host ?? url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .textCase(.uppercase)
                        if let title = post.articleTitle {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(10)
                .background(AppColors.base(colorScheme))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Header

    @ViewBuilder
    private var postHeader: some View {
        if let community = post.community {
            communityPostHeader(community)
        } else {
            regularPostHeader
        }
    }

    /// A post that surfaced in Feed from a community: the community's own
    /// avatar/name lead as the primary identity (so it's immediately clear
    /// which community this came from), with the actual poster as a smaller
    /// secondary line — same information `CommunityPostCard`'s small tag row
    /// used to bury below the personal header, promoted to the primary spot
    /// per the "which community, from which one" framing this was asked for.
    private func communityPostHeader(_ community: CommunityRef) -> some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(destination:
                CommunityDetailView(communityId: community.id, token: appState.authToken ?? "",
                                     currentUserId: appState.currentUser?.id ?? "")
                    .environment(appState).environment(themeManager)
            ) {
                Avatar(name: community.iconEmoji, imageURL: community.avatarUrl, size: .md)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                NavigationLink(destination:
                    CommunityDetailView(communityId: community.id, token: appState.authToken ?? "",
                                         currentUserId: appState.currentUser?.id ?? "")
                        .environment(appState).environment(themeManager)
                ) {
                    Text(community.name)
                        .appFont(.headline)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                .buttonStyle(.plain)

                Text(String(format: bundle.loc("Posted by %@"), post.author.name))
                    .appFont(.footnote)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)

                HStack(spacing: 3) {
                    if post.isPinned {
                        Image(systemName: "pin.fill")
                        Text("Pinned", bundle: bundle)
                        Text("·")
                    }
                    Text(post.timestamp.timeAgoString)
                }
                .appFont(.footnote)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            postHeaderMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var regularPostHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar → shake (own profile) | Profile tab (own feed) | UserProfileView (someone else)
            let isSelf = post.author.id == appState.currentUser?.id
            if disableSelfNavigation && isSelf {
                Button { triggerShake() } label: {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            } else if isSelf, let onTap = onOwnAvatarTapped {
                Button { onTap() } label: {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(destination:
                    UserProfileView(userId: post.author.id, preloadedUser: post.author)
                        .environment(appState)
                ) {
                    AvatarView(user: post.author, size: 42)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Name + Connect button in one row
                HStack(spacing: 8) {
                    NavigationLink(destination:
                        UserProfileView(userId: post.author.id, preloadedUser: post.author)
                            .environment(appState)
                    ) {
                        Text(post.author.name)
                            .appFont(.headline)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .buttonStyle(.plain)

                    // Only show Connect if this isn't the current user
                    if post.author.id != appState.currentUser?.id {
                        ConnectButton(targetUserId: post.author.id, compact: true)
                    }
                }

                if post.mode == .work,
                   let title = post.author.jobTitle,
                   let company = post.author.company {
                    Text("\(title) · \(company)")
                        .appFont(.footnote)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                HStack(spacing: 3) {
                    Text(post.timestamp.timeAgoString)
                    Text("·")
                    Image(systemName: post.privacy == .publicAll ? "globe.americas" : post.privacy.icon)
                }
                .appFont(.footnote)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            postHeaderMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var postHeaderMenu: some View {
        Menu {
            let isSelf = post.author.id == appState.currentUser?.id
            if isSelf {
                Button { showEditSheet = true } label: {
                    Label(bundle.loc("Edit post"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    // Delay so the menu finishes dismissing before the alert appears (SwiftUI timing bug)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showDeleteAlert = true
                    }
                } label: {
                    Label(bundle.loc("Delete post"), systemImage: "trash")
                }
            } else {
                Button {
                    handleHidePost()
                } label: {
                    Label(bundle.loc("Hide post"), systemImage: "eye.slash")
                }
                Button(role: .destructive) {
                    showReportDialog = true
                } label: {
                    Label(bundle.loc("Report post"), systemImage: "flag")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }

    // MARK: Hashtag Chips

    /// List of the post's hashtags — tapping a chip opens TagFeedView to browse that tag
    private var hashtagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(post.tags, id: \.self) { tag in
                    NavigationLink(destination: TagFeedView(tag: tag, mode: appState.currentMode)) {
                        Chip(text: "#\(tag)", style: .neutral)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Action Buttons

    /// Count shown immediately to the right of an action icon (hidden at 0) —
    /// same style the old FB-style summary row above the divider used to have.
    @ViewBuilder
    private func actionCount(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .appFont(.subheadline)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    private var actionButtons: some View {
        HStack {
            // Like + Comment — bottom left
            HStack(spacing: 16) {
                Button {
                    Task {
                        // Optimistic toggle, then reconcile with the server —
                        // and roll back (like the Save button below) if it fails.
                        let wasLiked = isLiked
                        let wasCount = likeCount
                        isLiked   = !isLiked
                        likeCount += isLiked ? 1 : -1
                        do {
                            let res = try await repository.toggleLike(postId: post.id)
                            isLiked   = res.liked
                            likeCount = res.likeCount
                        } catch {
                            isLiked   = wasLiked
                            likeCount = wasCount
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 20))
                            .foregroundColor(isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                        actionCount(likeCount)
                    }
                }

                Button {
                    if let onOpenDetail { onOpenDetail(true) } else { showComments = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 20))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(commentCount)
                    }
                }
            }

            Spacer()

            // Save + Share — bottom right
            HStack(spacing: 16) {
                Button {
                    Task {
                        isSaved.toggle()
                        do {
                            if isSaved { try await repository.savePost(postId: post.id) }
                            else       { try await repository.unsavePost(postId: post.id) }
                            var updated = post
                            updated.isSaved = isSaved
                            NotificationCenter.default.post(name: .postUpdated, object: nil, userInfo: ["post": updated])
                        } catch {
                            isSaved.toggle() // revert on failure
                        }
                    }
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 20))
                        .foregroundColor(isSaved ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                }

                Button { showShareSheet = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.system(size: 20))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(shareCount)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Shared post embed

    /// Card for the original post embedded in a shared post; deleted original → placeholder
    @ViewBuilder
    private var sharedPostEmbed: some View {
        Group {
            if let shared = post.sharedPost {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AvatarView(user: shared.author, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(shared.author.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            Text(shared.timestamp.timeAgoString)
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }

                    if !shared.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(shared.content)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .lineLimit(6)
                    }

                    if !shared.displayImageUrls.isEmpty {
                        PostPhotoGrid(urls: shared.displayImageUrls, gridHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This content no longer exists", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
        )
    }
}

// MARK: - Height measuring (feeds PostCard's collapsedTotalHeight budget)

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    /// Reports this view's rendered height via `onChange` without affecting
    /// its own layout (measured through a zero-size `.background`).
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}
