import SwiftUI

/// "Saved", the user's own bookmarked posts, newest saved first, with saved
/// Marketplace items on their own tab. Reached from
/// Settings → Account, alongside "Recently Deleted". Structurally modeled on
/// RecentlyDeletedView (own PostRepository, single fetch, no pagination for
/// v1, empty state) but renders full `PostCard` per row (not a compact inert
/// row) since saved posts should stay fully interactive (like, comment,
/// share, unsave, all still work from here).
struct SavedPostsView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = SavedPostsViewModel()
    @State private var detailRoute: PostRoute?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("", selection: $viewModel.tab) {
                    Text("Posts", bundle: bundle).tag(SavedPostsViewModel.Tab.posts)
                    Text("Marketplace", bundle: bundle).tag(SavedPostsViewModel.Tab.marketplace)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppSpacing.sm)

                if viewModel.isEmpty && !viewModel.isLoading {
                    emptyState
                } else if viewModel.tab == .posts {
                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(viewModel.posts) { post in
                            PostCard(post: post, onOpenDetail: { focus in
                                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                            })
                            .cardStyle()
                        }
                    }
                    .padding(.horizontal, AppSpacing.sm)
                } else {
                    // The same white item cards as the Marketplace tab.
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.listings) { ListingCard(post: $0) }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
            }
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
            if viewModel.isLoading && viewModel.isEmpty {
                ProgressView()
            }
        }
        .task(id: viewModel.tab) { await viewModel.load() }
        .refreshable { await viewModel.load(force: true) }
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
            Text(bundle.loc(viewModel.tab == .posts ? "No saved posts" : "No saved items"))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
