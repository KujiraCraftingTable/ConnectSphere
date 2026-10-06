import SwiftUI

/// Browse posts by hashtag — opened by tapping a tag chip on PostCard.
struct TagFeedView: View {
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let tag: String
    /// Scopes tag browsing to the mode the tag chip was tapped from — matches
    /// every other post-list surface (main Feed, connections scope) being
    /// mode-scoped, instead of mixing hobby and work posts together.
    let mode: AppMode

    @State private var viewModel: TagFeedViewModel
    @State private var detailRoute: PostRoute?

    init(tag: String, mode: AppMode) {
        self.tag = tag
        self.mode = mode
        _viewModel = State(initialValue: TagFeedViewModel(tag: tag, mode: mode))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.sm) {
                if viewModel.isLoading && viewModel.posts.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if let loadError = viewModel.loadError, viewModel.posts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text(loadError)
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(.horizontal, 32)
                        Button(bundle.loc("Retry")) { Task { await viewModel.load() } }
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.top, 60)
                } else if viewModel.posts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "number")
                            .font(.system(size: 36))
                            .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                        Text("No posts with this tag yet", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.top, 60)
                } else {
                    ForEach(viewModel.posts) { post in
                        PostCard(
                            post: post,
                            onPostDeleted: { viewModel.remove(id: post.id) },
                            onPostUpdated: { viewModel.update($0) },
                            onOpenDetail: { focus in
                                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                            }
                        )
                        .cardStyle()
                        .onAppear {
                            // Scrolled to the last post → load the next page
                            if post.id == viewModel.posts.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView().padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 10)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        // `isPresented:` (not `item:`) — TagFeedView shares its host's
        // NavigationStack, which may already carry a PostRoute `item:`
        // destination (from FeedView); type-keyed `item:` destinations collide,
        // boolean ones don't.
        .navigationDestination(isPresented: Binding(
            get: { detailRoute != nil },
            set: { if !$0 { detailRoute = nil } }
        )) {
            if let route = detailRoute {
                PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
