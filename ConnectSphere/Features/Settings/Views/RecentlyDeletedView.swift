import SwiftUI

/// "Recently Deleted", the user's own soft-deleted posts (30-day
/// retention, auto-purged server-side), each restorable in place.
/// Reached from Settings → Account, alongside Notifications/Privacy & Security.
struct RecentlyDeletedView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = RecentlyDeletedViewModel()
    /// Post awaiting restore confirmation: browsed well after the fact, so a
    /// restore here is confirmed, unlike the post Undo toast.
    @State private var pendingRestore: PendingRestore? = nil

    private enum PendingRestore: Identifiable {
        case post(Post)
        var id: String {
            switch self {
            case .post(let p):    return "post-\(p.id)"
            }
        }
        var alertTitleKey: String {
            switch self {
            case .post:    return "Restore this post?"
            }
        }
    }

    var body: some View {
        List {
            postsSection
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
            Text("Deleted posts are kept for 30 days, then removed permanently.", bundle: bundle)
        }
    }

    // MARK: - Rows

    private func deletedPostRow(_ post: Post) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !post.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(post.content)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(3)
                } else if !post.displayImageUrls.isEmpty {
                    Text("Photo post", bundle: bundle)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if post.linkUrl != nil {
                    Text("Link post", bundle: bundle)
                        .scaledFont(14)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Text(post.timestamp.timeAgoString)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer(minLength: 8)
            restoreButton(isLoading: viewModel.restoringPostIds.contains(post.id)) {
                pendingRestore = .post(post)
            }
        }
        .padding(.vertical, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .scaledFont(14)
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
                    .scaledFont(13, .semibold)
                    .foregroundColor(themeManager.theme.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
