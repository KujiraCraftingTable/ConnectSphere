import SwiftUI

/// Duyệt bài viết theo hashtag — mở khi bấm vào tag chip trên PostCard.
struct TagFeedView: View {
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let tag: String

    @State private var posts: [Post] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var offset = 0
    @State private var hasMore = true

    private let repository = PostRepository()
    private let pageSize = 20

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if isLoading && posts.isEmpty {
                    ProgressView().padding(.top, 60)
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
                            // Cuộn tới bài cuối → tải trang tiếp theo
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

    /// Tải trang đầu (reset phân trang)
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        offset = 0
        hasMore = true
        let fetched = (try? await repository.fetchPostsByTag(tag, limit: pageSize, offset: 0)) ?? []
        posts = fetched
        offset = fetched.count
        hasMore = fetched.count == pageSize
    }

    /// Tải trang tiếp theo khi cuộn tới cuối danh sách
    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let fetched = (try? await repository.fetchPostsByTag(tag, limit: pageSize, offset: offset)) ?? []
        let existingIds = Set(posts.map(\.id))
        posts += fetched.filter { !existingIds.contains($0.id) }
        offset += fetched.count
        hasMore = fetched.count == pageSize
    }
}
