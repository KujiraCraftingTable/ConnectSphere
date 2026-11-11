import SwiftUI

struct PostCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(UndoToastPresenter.self) var toastPresenter
    @AppStorage(TranslationMode.storageKey) private var translationModeRaw = TranslationMode.original.rawValue
    private var translationMode: TranslationMode { TranslationMode(rawValue: translationModeRaw) ?? .original }
    private var translations: TranslationStore { .shared }
    @State private var actions: PostActionsViewModel
    @State private var showComments  = false
    @State private var showShareSheet = false

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
    /// Replaces the comment sheet when set. The post's own page focuses its
    /// comment box instead of popping a sheet over the comments it already shows.
    var onCommentTap: (() -> Void)? = nil
    /// Staff-only pin/unpin for a community post. Set (non-nil) only by a
    /// caller that has already verified the viewer is an admin/moderator of
    /// `post.community`; `nil` on every non-community call site, and on a
    /// community post viewed by a regular member.
    var onPin: (() -> Void)? = nil
    var onUnpin: (() -> Void)? = nil
    /// Whether to show the header's connect/Add friend/Accept-Decline
    /// button. Default `true` everywhere (Profile/Community/Search); `false`
    /// on the main Feed, where the author's name is already a link to their
    /// profile if you want to connect from there.
    var showConnectButton: Bool = true
    /// Corner radius for the card's own clip shape.
    var cornerRadius: CGFloat = 12
    /// `false` in `PostDetailView`, whose top bar shows the author and the ⋯
    /// menu instead, so the card starts with the post itself.
    var showsHeader: Bool = true
    /// The community whose page this card is on (its feed, a member's profile
    /// there…). Naming the community on every post would be redundant, so the
    /// header shows the poster, and tapping them, yourself included, pops up
    /// their profile in this community. Covers Marketplace items listed there too.
    var insideCommunityId: String? = nil
    /// A post waiting for approval, shown to the reviewer: not live yet, so
    /// there's nothing to react to, comment on, save, share or open a menu for.
    var isReviewOnly: Bool = false

    @State private var shakeAmount: CGFloat = 0
    /// Drives the in-app browser (see `openLink(_:)`) for a tapped http(s)
    /// link, the link-preview card or an in-text URL.
    @State private var inAppBrowserURL: URL?
    /// The listing photo on screen, so the item list below can highlight its item.
    @State private var listingPhotoIndex = 0

    init(
        post: Post,
        disableSelfNavigation: Bool = false,
        onOwnAvatarTapped: (() -> Void)? = nil,
        onCommentAdded: (() -> Void)? = nil,
        onPostDeleted: (() -> Void)? = nil,
        onPostUpdated: ((Post) -> Void)? = nil,
        onOpenDetail: ((_ focusComposer: Bool) -> Void)? = nil,
        onCommentTap: (() -> Void)? = nil,
        onPin: (() -> Void)? = nil,
        onUnpin: (() -> Void)? = nil,
        showConnectButton: Bool = true,
        cornerRadius: CGFloat = 12,
        showsHeader: Bool = true,
        insideCommunityId: String? = nil,
        isReviewOnly: Bool = false
    ) {
        self.post = post
        self.disableSelfNavigation = disableSelfNavigation
        self.onOwnAvatarTapped = onOwnAvatarTapped
        self.onCommentAdded = onCommentAdded
        self.onPostDeleted = onPostDeleted
        self.onPostUpdated = onPostUpdated
        self.onOpenDetail = onOpenDetail
        self.onCommentTap = onCommentTap
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.showConnectButton = showConnectButton
        self.cornerRadius = cornerRadius
        self.showsHeader = showsHeader
        self.insideCommunityId = insideCommunityId
        self.isReviewOnly = isReviewOnly
        _actions = State(initialValue: PostActionsViewModel(post: post))
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let kind = actions.hiddenKind {
                // Stays in place, with Undo, until the feed is refreshed.
                HiddenPostPlaceholder(kind: kind, cornerRadius: cornerRadius) {
                    Task { await actions.undoHidden() }
                }
            } else {
                mainCard
            }
        }
        .animation(.default, value: actions.hiddenKind)
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                postHeader
                postBody
            } else {
                // The header's top inset, which the body's own 10 pt continues.
                postBody.padding(.top, 2)
            }
            if isReviewOnly {
                Spacer().frame(height: 12)
            } else {
                Divider().padding(.horizontal, 12).padding(.top, 8)
                actionButtons
            }
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .offset(x: shakeAmount)
        // Whole-card tap-to-open, placed on the outer container so it covers
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
                actions.adjustCommentCount(by: delta)
                if delta > 0 { onCommentAdded?() }
            }
            .environment(appState)
        }
        // Share sheet
        .sheet(isPresented: $showShareSheet) {
            SharePostSheet(post: post) {
                actions.didShare()
            }
            .environment(appState)
            .environment(themeManager)
        }
        // Resyncs the locally-tracked count whenever a fresh `post` value
        // flows in from the parent (e.g. after `.postUpdated` patches this
        // post's entry in FeedViewModel/ProfileViewModel following a comment
        // add/delete elsewhere), `@State`'s `initialValue` only seeds once
        // per view identity, so without this the row would keep showing a
        // stale count until the app fully reloads it. Mirrors the same
        // pattern already used in `CommunityPostCard`.
        .onChange(of: post.commentCount) { _, newValue in actions.syncCommentCount(newValue) }
    }

    // MARK: Body

    /// Everything between the header and the action row: text, hashtags, link
    /// preview / photos, shared-post embed, poll / event. The whole-card tap
    /// (see `mainCard`) covers this region too; the link-preview card, tag
    /// chips, and poll/event controls keep handling their own taps.
    @ViewBuilder
    private var postBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content, only shown if there's actual text
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
                if canTranslatePost {
                    TranslationToggle(showingTranslation: showsPostTranslation) {
                        withAnimation(.snappy) { translations.toggle(TranslationStore.key(post: post.id)) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }
            }

            // Hashtag chips, tapping one opens TagFeedView to browse by tag
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
            // Real uploaded images, Facebook-style grid, supports multiple images
            else if !post.displayImageUrls.isEmpty {
                if post.postType == .listing {
                    // An item for sale: its photos one at a time, as in the Marketplace.
                    // With several items, one photo per item, each with its price drawn on.
                    ListingPhotoCarousel(urls: post.displayImageUrls, aspectRatio: 4.0 / 3.0, cornerRadius: 0,
                                         tags: post.listingData?.photoTags(count: post.displayImageUrls.count, loc: bundle.loc),
                                         currentIndex: $listingPhotoIndex)
                        .padding(.top, 10)
                } else {
                    PostPhotoGrid(urls: post.displayImageUrls, alts: post.displayImageAlts,
                                  viewerBar: { closeThen in AnyView(viewerActionBar(closeThen: closeThen)) })
                        .padding(.top, 10)
                }
            }

            // Embedded original post (if this is a shared post)
            if let shared = post.sharedCommunity {
                SharedCommunityCard(community: shared)
                    .padding(.horizontal, 12)
            }
            if post.sharedPostId != nil {
                sharedPostEmbed
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            // Poll or Event inline body. Same PollPostCard/EventPostCard used by
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
            case .job:
                if let jobData = post.jobData {
                    JobPostCard(
                        vm: JobViewModel(jobData: jobData, token: appState.authToken ?? ""),
                        poster: post.author,
                        accentColor: themeManager.theme.primary
                    )
                    .padding(.top, 10)
                }
            case .listing:
                ListingPostCard(post: post, photoIndex: listingPhotoIndex)
                    .padding(.top, 10)
            case .text:
                EmptyView()
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

    private var canTranslatePost: Bool {
        ContentTranslation.isAvailable(lang: post.contentLang, translated: post.translatedContent,
                                       appLanguage: appState.appLanguage)
    }

    private var showsPostTranslation: Bool {
        canTranslatePost && translations.showsTranslation(TranslationStore.key(post: post.id), mode: translationMode)
    }

    /// The post's own words, or the server-made translation in their place.
    private var displayedContent: String {
        showsPostTranslation ? (post.translatedContent ?? post.content) : post.content
    }

    private var linkifiedContent: AttributedString {
        let text = displayedContent
        if post.isMarkdown {
            return MarkdownFormatter.attributed(text, linkColor: themeManager.theme.primary,
                                                quoteColor: AppColors.textSecondary(colorScheme))
        }
        var result = AttributedString(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: text) else { continue }
            if let attrRange = Range(range, in: result) {
                result[attrRange].link = url
                result[attrRange].foregroundColor = themeManager.theme.primary
            }
        }
        return result
    }

    // MARK: Links

    /// http(s) → the in-app browser (matches Facebook/X/Instagram). Other
    /// schemes (`tel:`, `sms:`, another app's link) are ignored: a post must
    /// not open another app without the reader choosing to.
    private func openLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        inAppBrowserURL = url
    }

    // MARK: Link Preview Card

    private func linkPreviewCard(url: URL) -> some View {
        Button { openLink(url) } label: {
            VStack(spacing: 0) {
                // Thumbnail
                if let imageUrl = APIConfig.mediaURL(post.imageUrl) {
                    RemoteImage(url: imageUrl) { phase in
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
                            .scaledFont(11)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .textCase(.uppercase)
                        if let title = post.articleTitle {
                            Text(title)
                                .scaledFont(14, .semibold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .scaledFont(12)
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
        if let communityId = insideCommunityId {
            posterHeader(communityId)
        } else if let community = post.community {
            communityPostHeader(community)
        } else {
            regularPostHeader
        }
    }

    /// A post that surfaced in Feed from a community: the community's own
    /// avatar/name lead as the primary identity (so it's immediately clear
    /// which community this came from), with the actual poster as a smaller
    /// secondary line, same information `CommunityPostCard`'s small tag row
    /// used to bury below the personal header, promoted to the primary spot
    /// per the "which community, from which one" framing this was asked for.
    private func communityPostHeader(_ community: CommunityRef) -> some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(destination:
                CommunityDetailView(communityId: community.id, token: appState.authToken ?? "",
                                     currentUserId: appState.currentUser?.id ?? "")
                    .environment(appState).environment(themeManager)
            ) {
                // Rounded-square (not circle) + the poster's own small
                // circular avatar badged on the bottom-right corner. Reads
                // as "a community post, by this person" in the avatar shape
                // alone, before even reading the text. Taller than a plain
                // circle, so the timestamp moves to its own line below to
                // give the extra height somewhere to go (see the VStack).
                Avatar(name: community.iconEmoji, imageURL: community.avatarUrl,
                       size: .md, shape: .roundedSquare)
            }
            .buttonStyle(.plain)
            // The poster's own small avatar opens their profile in this community.
            .overlay(alignment: .bottomTrailing) {
                CommunityProfileLink(communityId: community.id, userId: post.author.id) {
                    Avatar(name: post.author.name, colorHex: post.author.avatarColor,
                           imageURL: post.author.avatarUrl, size: .xs)
                        .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 2))
                }
                .offset(x: 6, y: 6)
            }

            VStack(alignment: .leading, spacing: 2) {
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

                CommunityProfileLink(communityId: community.id, userId: post.author.id) {
                    Text(String(format: bundle.loc("Posted by %@"), post.author.name))
                        .lineLimit(1)
                        .appFont(.footnote)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }

                HStack(spacing: 3) {
                    if post.isPinned {
                        Image(systemName: "pin.fill")
                        Text("Pinned", bundle: bundle)
                        Text("·")
                    }
                    Text(post.timestamp.timeAgoString)
                    if let audience = post.community?.audience {
                        // Who can see it: anyone, or the community only.
                        Text("·")
                        Image(systemName: audience.icon)
                            .accessibilityLabel(Text(bundle.loc(audience.label)))
                    }
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

    /// The author's avatar or name: on your own profile it shakes the post
    /// ("you're already here"), in your own feed it opens your Profile tab,
    /// and anyone else's opens their profile. Avatar and name behave the same.
    @ViewBuilder
    private func authorLink<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        let isSelf = post.author.id == appState.currentUser?.id
        if disableSelfNavigation && isSelf {
            Button { triggerShake() } label: { label() }
                .buttonStyle(.plain)
        } else if isSelf, let onTap = onOwnAvatarTapped {
            Button { onTap() } label: { label() }
                .buttonStyle(.plain)
        } else {
            NavigationLink(destination:
                UserProfileView(userId: post.author.id, preloadedUser: post.author)
                    .environment(appState)
            ) { label() }
            .buttonStyle(.plain)
        }
    }

    private var regularPostHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            authorLink { AvatarView(user: post.author, size: 42) }

            VStack(alignment: .leading, spacing: 3) {
                // Name + Connect button in one row
                HStack(spacing: 8) {
                    authorLink {
                        Text(post.author.name)
                            .appFont(.headline)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    if post.author.isOfficial { OfficialBadge(compact: true).padding(.leading, -5) }

                    // Only show Connect if this isn't the current user
                    // The official account neither connects nor is connected with.
                    if showConnectButton && post.author.id != appState.currentUser?.id && !post.author.isOfficial
                        && !(appState.currentUser?.isOfficial ?? false) {
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

    /// A community post seen inside its community: the poster, like a feed
    /// post's header, with "Pinned" when it is.
    private func posterHeader(_ communityId: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CommunityProfileLink(communityId: communityId, userId: post.author.id) {
                AvatarView(user: post.author, size: 42)
            }
            VStack(alignment: .leading, spacing: 3) {
                CommunityProfileLink(communityId: communityId, userId: post.author.id) {
                    Text(post.author.name)
                        .appFont(.headline)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                HStack(spacing: 3) {
                    if post.isPinned {
                        Image(systemName: "pin.fill")
                        Text("Pinned", bundle: bundle)
                        Text("·")
                    }
                    Text(post.timestamp.timeAgoString)
                    if let audience = post.community?.audience {
                        // Who can see it: anyone, or the community only.
                        Text("·")
                        Image(systemName: audience.icon)
                            .accessibilityLabel(Text(bundle.loc(audience.label)))
                    }
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

    @ViewBuilder
    private var postHeaderMenu: some View {
        if !isReviewOnly {
            PostOptionsMenu(post: post, actions: actions, onPin: onPin, onUnpin: onUnpin,
                            onPostDeleted: onPostDeleted, onPostUpdated: onPostUpdated)
        }
    }

    // MARK: Hashtag Chips

    /// List of the post's hashtags. Tapping a chip opens TagFeedView to browse that tag
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

    /// Count shown immediately to the right of an action icon (hidden at 0),
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
            // Like + Comment. Bottom left
            HStack(spacing: 16) {
                Button {
                    Task { await actions.toggleLike(postId: post.id) }
                } label: {
                    HStack(spacing: 4) {
                        LikeIcon(isLiked: actions.isLiked,
                                 color: actions.isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme),
                                 size: 26)
                        actionCount(actions.likeCount)
                    }
                }
                .accessibilityLabel(Bundle.app.loc("Whale"))
                .disabledWhenRestricted()

                Button {
                    if let onOpenDetail { onOpenDetail(true) } else if let onCommentTap { onCommentTap() } else { showComments = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .scaledFont(20)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(actions.commentCount)
                    }
                }
                .accessibilityLabel(Bundle.app.loc("Comment"))
            }

            Spacer()

            // Save + Share. Bottom right
            HStack(spacing: 16) {
                // The official account visits communities and the Marketplace without saving.
                if !((post.community != nil || post.postType == .listing) && (appState.currentUser?.isOfficial ?? false)) {
                    Button {
                        Task { await actions.toggleSave(post: post) }
                    } label: {
                        Image(systemName: actions.isSaved ? "bookmark.fill" : "bookmark")
                            .scaledFont(20)
                            .foregroundColor(actions.isSaved ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                    }
                    .accessibilityLabel(actions.isSaved ? Bundle.app.loc("Unsave") : Bundle.app.loc("Save"))
                }

                // The official account monitors the Marketplace without sharing items.
                if !(post.postType == .listing && (appState.currentUser?.isOfficial ?? false)) {
                Button { showShareSheet = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .scaledFont(20)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        actionCount(actions.shareCount)
                    }
                }
                .accessibilityLabel(Bundle.app.loc("Share"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The post's whale / comment / save / share under a full-screen photo.
    /// Comments open full height over the photo; share closes the photo first.
    private func viewerActionBar(closeThen: @escaping (@escaping () -> Void) -> Void) -> some View {
        PostViewerActionBar(
            actions: actions,
            post: post,
            accent: themeManager.theme.primary,
            canSave: !((post.community != nil || post.postType == .listing) && (appState.currentUser?.isOfficial ?? false)),
            canShare: !(post.postType == .listing && (appState.currentUser?.isOfficial ?? false)),
            onCommentAdded: onCommentAdded,
            onShare: { closeThen { showShareSheet = true } })
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
                                .scaledFont(14, .semibold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            Text(shared.timestamp.timeAgoString)
                                .scaledFont(12)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }

                    if !shared.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let canTranslate = ContentTranslation.isAvailable(lang: shared.contentLang, translated: shared.translatedContent,
                                                                          appLanguage: appState.appLanguage)
                        let key = TranslationStore.key(post: shared.id)
                        let translated = canTranslate && translations.showsTranslation(key, mode: translationMode)
                        let sharedText = translated ? (shared.translatedContent ?? shared.content) : shared.content
                        Text(shared.isMarkdown
                             ? MarkdownFormatter.attributed(sharedText, linkColor: themeManager.theme.primary,
                                                            quoteColor: AppColors.textSecondary(colorScheme))
                             : AttributedString(sharedText))
                            .scaledFont(14)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .environment(\.openURL, OpenURLAction { url in openLink(url); return .handled })
                            .lineLimit(6)
                        if canTranslate {
                            TranslationToggle(showingTranslation: translated, fontSize: 12) {
                                withAnimation(.snappy) { translations.toggle(key) }
                            }
                        }
                    }

                    if !shared.displayImageUrls.isEmpty {
                        PostPhotoGrid(urls: shared.displayImageUrls, alts: shared.displayImageAlts, gridHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("This content no longer exists", bundle: bundle)
                    .scaledFont(14)
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

/// Whale / comment / save / share in white on the full-screen photo viewer.
/// Its own view so it follows `actions` live while the viewer is open.
private struct PostViewerActionBar: View {
    let actions: PostActionsViewModel
    let post: Post
    let accent: Color
    let canSave: Bool
    let canShare: Bool
    var onCommentAdded: (() -> Void)?
    let onShare: () -> Void
    @State private var showComments = false

    private var buttons: some View {
        HStack(spacing: 22) {
            Button {
                Task { await actions.toggleLike(postId: post.id) }
            } label: {
                HStack(spacing: 6) {
                    LikeIcon(isLiked: actions.isLiked, color: actions.isLiked ? accent : .white, size: 26)
                    count(actions.likeCount)
                }
            }
            .accessibilityLabel(Bundle.app.loc("Whale"))
            .disabledWhenRestricted()

            Button { showComments = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").scaledFont(22)
                    count(actions.commentCount)
                }
            }
            .accessibilityLabel(Bundle.app.loc("Comment"))

            Spacer()

            if canSave {
                Button {
                    Task { await actions.toggleSave(post: post) }
                } label: {
                    Image(systemName: actions.isSaved ? "bookmark.fill" : "bookmark")
                        .scaledFont(22)
                        .foregroundColor(actions.isSaved ? accent : .white)
                }
                .accessibilityLabel(actions.isSaved ? Bundle.app.loc("Unsave") : Bundle.app.loc("Save"))
            }
            if canShare {
                Button(action: onShare) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrowshape.turn.up.right").scaledFont(22)
                        count(actions.shareCount)
                    }
                }
                .accessibilityLabel(Bundle.app.loc("Share"))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Who posted it, like Facebook: the community first for a community post.
            VStack(alignment: .leading, spacing: 2) {
                Text(post.community?.name ?? post.author.name)
                    .scaledFont(16, .semibold)
                    .lineLimit(1)
                Text(post.community != nil
                     ? "\(post.author.name) · \(post.timestamp.timeAgoString)"
                     : post.timestamp.timeAgoString)
                    .scaledFont(13)
                    .opacity(0.75)
                    .lineLimit(1)
            }
            buttons
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .sheet(isPresented: $showComments) {
            CommentSheet(postId: post.id, postAuthorId: post.author.id, onCommentCountChange: { delta in
                actions.adjustCommentCount(by: delta)
                if delta > 0 { onCommentAdded?() }
            }, fullHeight: true)
        }
    }

    @ViewBuilder
    private func count(_ value: Int) -> some View {
        if value > 0 { Text("\(value)").scaledFont(15, .semibold) }
    }
}
