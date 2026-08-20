import SwiftUI

/// Màn hình xem một bài viết — mở từ notification (like/comment/reply).
/// Fetch bài theo id rồi render bằng PostCard sẵn có.
struct PostDetailView: View {
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    let postId: String

    @State private var post: Post?
    @State private var loadFailed = false

    private let repository = PostRepository()

    var body: some View {
        ScrollView {
            if let post {
                PostCard(
                    post: post,
                    onPostDeleted: { dismiss() },
                    onPostUpdated: { updated in self.post = updated }
                )
                .padding(.top, 8)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                    Text("This post no longer exists or you don't have permission to view it", bundle: bundle)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 80)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Posts"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { post = try await repository.fetchPost(id: postId) }
            catch { loadFailed = true }
        }
    }
}
