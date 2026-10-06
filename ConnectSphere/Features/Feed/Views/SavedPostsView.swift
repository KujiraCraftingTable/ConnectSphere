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

    @State private var viewModel = SavedPostsViewModel()
    @State private var detailRoute: PostRoute?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.sm) {
                if viewModel.posts.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    ForEach(viewModel.posts) { post in
                        PostCard(post: post, onOpenDetail: { focus in
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        })
                        .cardStyle()
                    }
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 12)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Saved"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { detailRoute != nil },
            set: { if !$0 { detailRoute = nil } }
        )) {
            if let route = detailRoute {
                PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.posts.isEmpty {
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
        .onReceive(NotificationCenter.default.publisher(for: .postUpdated)) { note in
            if let updated = note.userInfo?["post"] as? Post { viewModel.postUpdated(updated) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .postDeleted)) { note in
            if let id = note.userInfo?["id"] as? String { viewModel.postDeleted(id: id) }
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
}
