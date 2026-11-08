import SwiftUI

/// The comment list + inline reply/edit/delete, extracted from the old
/// `CommentSheet` so it can render inline on the pushed `PostDetailView`
/// (comments below the post) as well as inside `CommentSheet` (still used by
/// `CommunityPostCard`). It renders *only* the list. The composer / reply
/// banner live with whoever hosts it, so the host can pin them outside the
/// scroll view and own the keyboard focus.
///
/// `viewModel` and `toastPresenter` are passed in rather than owned: the host
/// shares its view model with its own pinned composer, and picks the toast
/// presenter that its context can actually display (the app-wide one on a
/// pushed screen, a private one inside a `.sheet`).
struct CommentsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let postId: String
    /// Set for a community post: names open the person's community profile.
    var communityId: String? = nil
    /// The post's own author. Compared against each comment's author to show
    /// the "Author" badge on their comments/replies.
    let postAuthorId: String
    let viewModel: CommentViewModel
    let toastPresenter: UndoToastPresenter
    /// Called after `viewModel.replyingTo` is set, so the host can focus its composer.
    var onReplyRequested: () -> Void = {}
    /// The comment a notification or the activity log jumped to: its row is
    /// tinted for a moment so the eye finds it.
    var highlightedCommentId: String? = nil
    /// Called with the change in total comment count whenever this section's
    /// own actions move it, `+1` after sending a comment/reply, `-N` after
    /// a delete (N = however many were actually removed, including any
    /// replies cascaded with a root), `+1` after undoing a delete. Lets the
    /// host (which owns the visible comment count) update immediately
    /// instead of waiting on a full refetch. The server's own count is
    /// already updated durably and remains the eventual source of truth.
    var onCommentCountChange: (Int) -> Void = { _ in }
    /// Told when a comment starts or stops being edited in place, so the host
    /// hides its "Write a comment" composer meanwhile (as Facebook does).
    var onEditingChange: (Bool) -> Void = { _ in }

    @State private var pendingDeleteCommentId: String? = nil
    @State private var reportingComment: CommentDTO? = nil
    @State private var historySubject: EditHistorySubject? = nil
    @State private var editingCommentId: String? = nil
    @State private var editingText: String = ""


    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.comments.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if viewModel.comments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left").scaledFont(40)
                        .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                    Text("No comments yet", bundle: bundle)
                        .scaledFont(15)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sortControl
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.parents) { comment in
                            commentBlock(comment)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .alert(
            bundle.loc("Delete comment?"),
            isPresented: Binding(
                get: { pendingDeleteCommentId != nil },
                set: { if !$0 { pendingDeleteCommentId = nil } }
            )
        ) {
            Button(bundle.loc("Delete"), role: .destructive) {
                if let id = pendingDeleteCommentId {
                    pendingDeleteCommentId = nil
                    Task { await handleDeleteComment(commentId: id) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This comment won't be shown in the app. You can restore it from Recently Deleted within 30 days.", bundle: bundle)
        }
        .onChange(of: editingCommentId) { _, id in onEditingChange(id != nil) }
        .sheet(item: $historySubject) { subject in
            EditHistoryView(subject: subject)
                .environment(themeManager)
        }
        .sheet(item: $reportingComment, onDismiss: {
            // A warned or banned comment is taken down: show the list without it.
            if appState.currentUser?.isOfficial ?? false { Task { await viewModel.load(postId: postId) } }
        }) { comment in
            if appState.currentUser?.isOfficial ?? false {
                // The official account warns or bans instead of reporting.
                AdminBanSheet(target: ModerationTarget(type: "comment", id: comment.id, userId: comment.author.id,
                                                       userName: comment.author.displayName,
                                                       mode: appState.currentMode.rawValue))
                    .environment(themeManager)
            } else {
                ReportSheet(subject: .content(.comment, id: comment.id),
                            blockUser: (comment.author.id, comment.author.displayName))
            }
        }
    }

    // MARK: - Sort control

    private var sortControl: some View {
        HStack {
            Menu {
                ForEach(CommentSortOrder.allCases) { order in
                    Button {
                        viewModel.sortOrder = order
                    } label: {
                        if viewModel.sortOrder == order {
                            Label(sortOrderLabel(order), systemImage: "checkmark")
                        } else {
                            Text(sortOrderLabel(order))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sortOrderLabel(viewModel.sortOrder))
                    Image(systemName: "chevron.down")
                        .scaledFont(10, .semibold)
                }
                .scaledFont(13, .bold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func sortOrderLabel(_ order: CommentSortOrder) -> String {
        switch order {
        case .oldest: return bundle.loc("Oldest first")
        case .newest: return bundle.loc("Newest first")
        }
    }

    // MARK: - Delete comment (with Undo toast)

    /// Deletes the comment then shows an Undo toast; tapping Undo calls restore
    /// then reloads the whole comment list.
    private func handleDeleteComment(commentId: String) async {
        let removed = await viewModel.deleteComment(postId: postId, commentId: commentId)
        if removed > 0 { onCommentCountChange(-removed) }
        toastPresenter.show(message: bundle.loc("Comment deleted")) {
            Task {
                // Restore only ever brings back the single deleted comment,
                // never its cascade-deleted replies, so the delta is always
                // exactly +1, however much `removed` subtracted above.
                if await viewModel.restoreComment(postId: postId, commentId: commentId) { onCommentCountChange(1) }
            }
        }
    }

    // MARK: - Comment block (root + indented replies)

    /// A thread is three levels deep: comment → reply → reply-to-reply. A reply
    /// to a third-level reply is stored beside it (the server places it under
    /// the same parent), so every row can be replied to and the tree never
    /// grows a fourth level. Every reply says who it answers.
    @ViewBuilder
    private func commentBlock(_ comment: CommentDTO) -> some View {
        let replies = viewModel.replies(for: comment.id)
        let subReplies = replies.map { viewModel.replies(for: $0.id) }
        let lines = ThreadDecoration.layout(replyCounts: subReplies.map(\.count))
        let lineColor = AppColors.borderDefault(colorScheme)

        row(comment, level: 0, answering: nil)
            .threadLines(lines.root, level: 0, color: lineColor)

        ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
            row(reply, level: 1, answering: comment)
                .threadLines(lines.replies[index].0, level: 1, color: lineColor)

            ForEach(Array(subReplies[index].enumerated()), id: \.element.id) { subIndex, subReply in
                row(subReply, level: 2, answering: reply)
                    .threadLines(lines.replies[index].1[subIndex], level: 2, color: lineColor)
            }
        }
    }

    /// One row at `level` (0–2), indented to match the thread lines.
    /// `answering` is the comment it sits under. The fallback for "replied
    /// to" when the server didn't say (replies written before it recorded it).
    private func row(_ comment: CommentDTO, level: Int, answering parent: CommentDTO?) -> some View {
        Group {
            if viewModel.isCollapsed(comment) {
                mutedRow(comment)
            } else {
                commentRow(comment, level: level, answering: parent)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.theme.primary.opacity(comment.id == highlightedCommentId ? 0.16 : 0))
                .animation(.easeOut(duration: 0.4), value: highlightedCommentId)
        )
        .id(comment.id)
        .padding(.leading, CGFloat(level) * ThreadLinesShape.indentStep)
    }

    /// Stands in for a comment containing a muted word: it keeps its place
    /// (and the thread lines) but not its text, until the user asks.
    private func mutedRow(_ comment: CommentDTO) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .scaledFont(12)
            Text("Hidden: contains a word you muted", bundle: bundle)
                .scaledFont(13)
            Text("·")
            Button { withAnimation(.snappy) { viewModel.reveal(comment.id) } } label: {
                Text("Show", bundle: bundle).scaledFont(13, .semibold)
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.theme.primary)
            Spacer(minLength: 0)
        }
        .foregroundColor(AppColors.textTertiary(colorScheme))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commentRow(_ comment: CommentDTO, level: Int, answering parent: CommentDTO?) -> some View {
        let target = comment.replyTo.map { CommentReplyTarget(name: $0.displayName, userId: $0.id) }
            ?? parent.map { CommentReplyTarget(name: $0.author.displayName, userId: $0.author.id) }
        return CommentRow(
            comment: comment,
            communityId: communityId,
            level: level,
            isOwn: comment.author.id == appState.currentUser?.id,
            isPostAuthor: comment.author.id == postAuthorId,
            isEditing: editingCommentId == comment.id,
            editingText: $editingText,
            editHasChanges: editingCommentId == comment.id && editingText != comment.content,
            replyTarget: target,
            onLike:   { Task { await viewModel.toggleLike(postId: postId, commentId: comment.id) } },
            onReply:  {
                viewModel.replyingTo = comment
                onReplyRequested()
            },
            onDelete: { pendingDeleteCommentId = comment.id },
            onReport: { reportingComment = comment },
            onEdit: { beginEditing(comment) },
            onViewHistory: comment.editedAt == nil ? nil : {
                historySubject = .comment(postId: postId, commentId: comment.id)
            },
            onSaveEdit: { Task { await saveEdit(commentId: comment.id) } },
            onCancelEdit: { editingCommentId = nil }
        )
    }

    // MARK: - Edit comment (inline)

    private func beginEditing(_ comment: CommentDTO) {
        editingCommentId = comment.id
        editingText = comment.content
    }

    private func saveEdit(commentId: String) async {
        let text = editingText
        let ok = await viewModel.updateComment(postId: postId, commentId: commentId, content: text)
        if ok { editingCommentId = nil }
    }
}

// MARK: - Comment Row

/// The person a reply is answering, spelled out as "replied to [name]" under
/// the replier's name. The indent alone can't say which of several siblings a reply
/// addresses. Paired name+id (not a bare `String?`) so the attribution text
/// and its `NavigationLink` destination can never drift apart.
struct CommentReplyTarget {
    let name: String
    let userId: String
}

struct CommentRow: View {
    /// Row geometry shared with `ThreadLinesShape`, which draws to the avatar.
    static let avatarSize: CGFloat = 36
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 6

    /// Name and "replied to" size per thread level (0–2): smaller the deeper
    /// the reply, so a long name still fits on one line in the narrower
    /// bubble. The comment text itself keeps one size, it's what people read.
    static func nameFontSize(level: Int) -> CGFloat { 13 - CGFloat(min(max(level, 0), 2)) }
    static func badgeFontSize(level: Int) -> CGFloat { 10 - 0.5 * CGFloat(min(max(level, 0), 2)) }
    /// The sizes a name may take, as a share of its level's size, tried in
    /// order until the line fits: fine steps first, so a real name shrinks
    /// only a few percent. The last is enough for a `DisplayNameRules.maxLength`
    /// name of the widest capital (W) on the deepest reply on a 6.1" iPhone
    /// (see `DisplayNameFitTests`).
    static let nameScales: [CGFloat] = [1, 0.97, 0.94, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.5, 0.45, 0.4]
    static let bubblePadding: CGFloat = 12
    static let avatarSpacing: CGFloat = 8

    @Environment(AppState.self) private var appState
    @AppStorage(TranslationMode.storageKey) private var translationModeRaw = TranslationMode.original.rawValue
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var inAppBrowserURL: URL?
    /// The admin acts in Review reports instead of reporting comments.
    private var viewerIsOfficial: Bool { appState.currentUser?.isOfficial ?? false }

    let comment: CommentDTO
    /// Set under a community post: names open the person's community profile.
    var communityId: String? = nil
    /// 0 for a comment, 1 for a reply, 2 for a reply to a reply.
    var level: Int = 0
    var isOwn: Bool = false
    /// True when this comment/reply was written by the post's own author,
    /// shows a small "Author" badge right after the name, so other readers
    /// can quickly spot the poster's own comments.
    var isPostAuthor: Bool = false
    /// True while this specific row is the one being edited inline.
    var isEditing: Bool = false
    /// Shared editing-text binding, owned by the host. Only meaningful while
    /// `isEditing` is true.
    var editingText: Binding<String> = .constant("")
    /// The edit differs from the saved text, so Cancel asks before discarding.
    var editHasChanges: Bool = false
    /// Set on every reply. Renders "replied to [name]" on its own line under
    /// this row's name, each tappable to its own profile.
    var replyTarget: CommentReplyTarget? = nil
    var onLike:   (() -> Void)? = nil
    var onReply:  (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onReport: (() -> Void)? = nil
    var onEdit:   (() -> Void)? = nil
    /// Set only when the comment has been edited.
    var onViewHistory: (() -> Void)? = nil
    var onSaveEdit:   (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    /// http(s) links open in the in-app browser, like links in posts; mail and
    /// phone links go to the system.
    private func openCommentLink(_ url: URL) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            inAppBrowserURL = url
        } else {
            openURL(url)
        }
    }

    private var canTranslate: Bool {
        ContentTranslation.isAvailable(lang: comment.lang, translated: comment.translatedText, appLanguage: appState.appLanguage)
    }

    private var showsTranslation: Bool {
        canTranslate && TranslationStore.shared.showsTranslation(
            TranslationStore.key(comment: comment.id),
            mode: TranslationMode(rawValue: translationModeRaw) ?? .original)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.avatarSpacing) {
            // The picture opens the profile too, like the name.
            profileLink(comment.author.id, isOfficial: comment.author.isOfficial) { avatar }

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    editRow
                } else {
                    bubble
                        .inAppBrowser(url: $inAppBrowserURL)
                        .contextMenu {
                            if isOwn, let onEdit {
                                Button(action: onEdit) {
                                    Label(bundle.loc("Edit comment"), systemImage: "pencil")
                                }
                            }
                            if let onViewHistory {
                                Button(action: onViewHistory) {
                                    Label(bundle.loc("View edit history"), systemImage: "clock.arrow.circlepath")
                                }
                            }
                            if isOwn, let onDelete {
                                Button(role: .destructive, action: onDelete) {
                                    Label(bundle.loc("Delete comment"), systemImage: "trash")
                                }
                            }
                            if !isOwn, !comment.author.isOfficial, let onReport {
                                Button(role: viewerIsOfficial ? .destructive : nil, action: onReport) {
                                    Label(bundle.loc(viewerIsOfficial ? "Warn or ban" : "Report comment"),
                                          systemImage: viewerIsOfficial ? "hand.raised.slash" : "flag")
                                }
                            }
                        }
                    // The photo is its own part, right under the text bubble, not inside it.
                    if let photo = comment.imageUrl {
                        CommentPhoto(path: photo)
                            .padding(.top, 2)
                    }
                }
                if !isEditing { metaRow }
            }
            // First claim on the row's width, ahead of the spacer, so a long
            // name gets the whole width before it shrinks.
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
    }

    /// Name line + text in a rounded bubble that hugs its content
    /// (Messenger/Facebook style, like the chat screen's bubbles). The grey
    /// `base` fill stands out on the white comments card in both modes.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Name + badge on one line: the badge keeps its size, and a long
            // name takes the largest size at which the whole line fits.
            ViewThatFits(in: .horizontal) {
                ForEach(Self.nameScales, id: \.self) { scale in
                    HStack(spacing: 4) {
                        profileLink(comment.author.id, isOfficial: comment.author.isOfficial) {
                            nameText(comment.author.displayName, scale: scale)
                        }
                        if comment.author.isOfficial { OfficialBadge(compact: true).padding(.leading, -2) }
                        if isPostAuthor { authorBadge }
                    }
                }
            }

            // On its own line: beside the name and badge it didn't fit a long name.
            if let replyTarget {
                ViewThatFits(in: .horizontal) {
                    ForEach(Self.nameScales, id: \.self) { scale in
                        HStack(spacing: 4) {
                            Text("replied to", bundle: bundle)
                                .font(.system(size: Self.nameFontSize(level: level)))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            profileLink(replyTarget.userId) {
                                nameText(replyTarget.name, scale: scale)
                            }
                        }
                    }
                }
            }

            // A photo-only comment has no text line (its photo sits below the bubble).
            if !comment.content.isEmpty {
                let shown = showsTranslation ? (comment.translatedText ?? comment.content) : comment.content
                Text(comment.isMarkdown
                     ? MarkdownFormatter.attributed(shown, linkColor: themeManager.theme.primary,
                                                    quoteColor: AppColors.textSecondary(colorScheme))
                     : AttributedString(shown))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in openCommentLink(url); return .handled })
            }
            if canTranslate {
                TranslationToggle(showingTranslation: showsTranslation, fontSize: 12) {
                    withAnimation(.snappy) { TranslationStore.shared.toggle(TranslationStore.key(comment: comment.id)) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, Self.bubblePadding)
        .padding(.vertical, 8)
        .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var authorBadge: some View {
        Text("Author", bundle: bundle)
            .font(.system(size: Self.badgeFontSize(level: level), weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(themeManager.theme.primary)
            .clipShape(Capsule())
    }

    private func nameText(_ name: String, scale: CGFloat) -> some View {
        Text(name)
            .font(.system(size: Self.nameFontSize(level: level) * scale, weight: .semibold))
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .lineLimit(1)
            .fixedSize()
    }

    /// Time · like · Reply under the bubble, inset to line up with its text.
    private var metaRow: some View {
        HStack(spacing: 14) {
            Text(comment.createdAt.timeAgoString)
                .scaledFont(12)
                .foregroundColor(AppColors.textSecondary(colorScheme))

            if let onLike {
                Button(action: onLike) {
                    HStack(spacing: 3) {
                        LikeIcon(isLiked: comment.isLiked,
                                 color: comment.isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme),
                                 size: 14)
                        if comment.likeCount > 0 {
                            Text("\(comment.likeCount)").scaledFont(12)
                        }
                    }
                    .foregroundColor(comment.isLiked ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
            }
            if let onReply {
                Button(action: onReply) {
                    Text("Reply", bundle: bundle)
                        .scaledFont(12, .semibold)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
    }

    /// Compact inline edit UI. Replaces the static content `Text` while
    /// `isEditing` is true. Single-line-ish; not a full-screen composer.
    /// Facebook-style: the text sits in a large box edited in place, with
    /// Cancel (asks first when the text changed) and Update under it.
    private var editRow: some View {
        VStack(alignment: .trailing, spacing: 8) {
            MarkdownTextEditor(text: editingText, placeholder: bundle.loc("Write a comment..."), size: 15,
                               minHeight: 88, maxHeight: 200, autofocus: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColors.borderStrong(colorScheme), lineWidth: 1))

            HStack(spacing: 10) {
                ConfirmCancelButton(hasChanges: editHasChanges) { onCancelEdit?() }
                    .buttonStyle(EditPillButtonStyle(fill: AppColors.elevated(colorScheme),
                                                     text: AppColors.textPrimary(colorScheme)))
                Button(bundle.loc("Update")) { onSaveEdit?() }
                    .buttonStyle(EditPillButtonStyle(fill: themeManager.theme.primary, text: .white))
                    .disabled(editingText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && comment.imageUrl == nil)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = APIConfig.mediaURL(comment.author.avatarUrl) {
            RemoteImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialCircle
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: comment.author.avatarColor))
                .frame(width: Self.avatarSize, height: Self.avatarSize)
            Text(String(comment.author.displayName.prefix(1)).uppercased())
                .scaledFont(14, .bold)
                .foregroundColor(.white)
        }
    }

    /// Under a community post, someone's community profile as a pop-up;
    /// elsewhere their profile page. The official account isn't a community
    /// member, so it always opens its profile page.
    @ViewBuilder
    private func profileLink<L: View>(_ userId: String, isOfficial: Bool = false,
                                      @ViewBuilder label: @escaping () -> L) -> some View {
        if let communityId, !isOfficial {
            CommunityProfileLink(communityId: communityId, userId: userId, label: label)
        } else {
            NavigationLink(destination: UserProfileView(userId: userId).environment(appState), label: label)
                .buttonStyle(.plain)
        }
    }
}

/// The rounded Cancel / Update buttons under a comment being edited.
private struct EditPillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(15, .semibold)
            .foregroundColor(text)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
    }
}
