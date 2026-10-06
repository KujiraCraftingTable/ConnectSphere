import SwiftUI

/// "Recently Deleted" — the user's own soft-deleted posts and comments
/// (30-day retention, auto-purged server-side), each restorable in place.
/// Reached from Settings → Account, alongside Notifications/Privacy & Security.
struct RecentlyDeletedView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = RecentlyDeletedViewModel()
    /// Post/comment awaiting restore confirmation — this screen's "Restore"
    /// button used to restore on a single tap; per your decision, confirming
    /// applies here (browsed anytime, well after the fact) but NOT the quick
    /// Undo toast right after deleting, which stays a single instant tap.
    @State private var pendingRestore: PendingRestore? = nil

    private enum PendingRestore: Identifiable {
        case post(Post)
        case comment(DeletedComment)
        var id: String {
            switch self {
            case .post(let p):    return "post-\(p.id)"
            case .comment(let c): return "comment-\(c.id)"
            }
        }
        var alertTitleKey: String {
            switch self {
            case .post:    return "Restore this post?"
            case .comment: return "Restore this comment?"
            }
        }
    }

    var body: some View {
        List {
            postsSection
            commentsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Recently Deleted"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isLoading && viewModel.isEmpty {
                ProgressView()
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .alert(
            viewModel.errorMessage ?? "",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button(bundle.loc("Done")) {}
        }
        .alert(
            pendingRestore.map { bundle.loc($0.alertTitleKey) } ?? "",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { item in
            Button(bundle.loc("Restore")) {
                pendingRestore = nil
                switch item {
                case .post(let post):       Task { await viewModel.restorePost(post) }
                case .comment(let comment): Task { await viewModel.restoreComment(comment) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("It will be shown in the app again.", bundle: bundle)
        }
    }

    // MARK: - Sections

    private var postsSection: some View {
        Section {
            if viewModel.deletedPosts.isEmpty {
                emptyRow(bundle.loc("No recently deleted posts"))
            } else {
                ForEach(viewModel.deletedPosts) { post in
                    deletedPostRow(post)
                }
            }
        } header: {
            Text("Posts", bundle: bundle)
        } footer: {
            Text("Deleted posts and comments are kept for 30 days, then removed permanently.", bundle: bundle)
        }
    }

    private var commentsSection: some View {
        Section {
            if viewModel.deletedComments.isEmpty {
                emptyRow(bundle.loc("No recently deleted comments"))
            } else {
                ForEach(viewModel.deletedComments) { comment in
                    deletedCommentRow(comment)
                }
            }
        } header: {
            Text("Comments", bundle: bundle)
        }
    }

    // MARK: - Rows

    private func deletedPostRow(_ post: Post) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(post.content)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(3)
                } else if !post.displayImageUrls.isEmpty {
                    Text("Photo post", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if post.linkUrl != nil {
                    Text("Link post", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(post.timestamp.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer(minLength: 8)
            restoreButton(isLoading: viewModel.restoringPostIds.contains(post.id)) {
                pendingRestore = .post(post)
            }
        }
        .padding(.vertical, 6)
    }

    private func deletedCommentRow(_ comment: DeletedComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(3)
                Text(comment.createdAt.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer(minLength: 8)
            restoreButton(isLoading: viewModel.restoringCommentIds.contains(comment.id)) {
                pendingRestore = .comment(comment)
            }
        }
        .padding(.vertical, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }

    private func restoreButton(isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
            } else {
                Text("Restore", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
