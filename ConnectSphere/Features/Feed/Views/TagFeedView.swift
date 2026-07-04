import SwiftUI

/// Duyệt bài viết theo hashtag — mở khi bấm vào tag chip trên PostCard.
struct TagFeedView: View {
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let tag: String

    @State private var posts: [Post] = []
    @State private var isLoading = false

    private let repository = PostRepository()

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
                        Text("Chưa có bài viết nào với tag này", bundle: bundle)
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        posts = (try? await repository.fetchPostsByTag(tag)) ?? []
    }
}
