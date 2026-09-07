import SwiftUI

/// "Saved" — the user's own bookmarked posts, newest saved first. Reached from
/// Settings → Account, alongside "Recently Deleted". Structurally modeled on
/// RecentlyDeletedView (own PostRepository, single fetch, no pagination for
/// v1, empty state) but renders full `PostCard` per row (not a compact inert
/// row) since saved posts should stay fully interactive (like, comment,
/// share, unsave — all still work from here).
struct SavedPostsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var savedPosts: [Post] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let repository = PostRepository()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if savedPosts.isEmpty && !isLoading {
                    emptyState
                } else {
                    ForEach(savedPosts) { post in
                        PostCard(post: post)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Saved"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && savedPosts.isEmpty {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert(
            errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(bundle.loc("Done")) {}
        }
        // A post's isSaved flips to false (unsaved from its own bookmark
        // button, wherever it's rendered) — this list must drop it right
        // away rather than waiting for a manual refresh. "Patch or remove" is
        // an asymmetry a generic post-list observer (e.g. FeedViewModel's,
        // which only ever patches an existing entry) doesn't need, but a
        // Saved list does — same asymmetry RecentlyDeletedView already
        // handles for delete/restore.
        .onReceive(NotificationCenter.default.publisher(for: .postUpdated)) { note in
            guard let updated = note.userInfo?["post"] as? Post else { return }
            if updated.isSaved {
                if let idx = savedPosts.firstIndex(where: { $0.id == updated.id }) {
                    savedPosts[idx] = updated
                }
            } else {
                savedPosts.removeAll { $0.id == updated.id }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .postDeleted)) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            savedPosts.removeAll { $0.id == id }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 36))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("No saved posts", bundle: bundle)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func load() async {
        isLoading = true
        savedPosts = (try? await repository.fetchSavedPosts()) ?? []
        isLoading = false
    }
}
