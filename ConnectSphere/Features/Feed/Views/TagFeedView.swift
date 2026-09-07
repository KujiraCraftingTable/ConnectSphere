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

    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var offset = 0
    @State private var hasMore = true

    private let repository = PostRepository()
    private let pageSize = 20

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if isLoading && posts.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if let loadError, posts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text(loadError)
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(.horizontal, 32)
                        Button(bundle.loc("Retry")) { Task { await load() } }
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.top, 60)
                } else if posts.isEmpty {
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
                    ForEach(posts) { post in
                        PostCard(
                            post: post,
                            onPostDeleted: { posts.removeAll { $0.id == post.id } },
                            onPostUpdated: { updated in
                                if let i = posts.firstIndex(where: { $0.id == updated.id }) {
                                    posts[i] = updated
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                radius: 4, x: 0, y: 2)
                        .onAppear {
                            // Scrolled to the last post → load the next page
                            if post.id == posts.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if isLoadingMore {
                        ProgressView().padding(.vertical, 12)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    /// Loads the first page (resets pagination)
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        offset = 0
        hasMore = true
        do {
            let fetched = try await repository.fetchPostsByTag(tag, mode: mode, limit: pageSize, offset: 0)
            posts = fetched
            offset = fetched.count
            hasMore = fetched.count == pageSize
        } catch {
            loadError = friendlyError(error)
        }
    }

    /// Loads the next page when the user scrolls to the end of the list
    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let fetched = (try? await repository.fetchPostsByTag(tag, mode: mode, limit: pageSize, offset: offset)) ?? []
        let existingIds = Set(posts.map(\.id))
        posts += fetched.filter { !existingIds.contains($0.id) }
        offset += fetched.count
        hasMore = fetched.count == pageSize
    }
}
