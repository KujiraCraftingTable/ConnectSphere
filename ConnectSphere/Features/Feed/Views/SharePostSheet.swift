import SwiftUI

/// Sheet chia sẻ (repost) một bài viết về tường của mình, kèm lời nhắn tùy chọn.
struct SharePostSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    let post: Post
    var onShared: (() -> Void)? = nil

    @State private var comment = ""
    @State private var isSharing = false
    @State private var shareFailed = false

    private let repository = PostRepository()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField(bundle.loc("Nói gì đó về bài viết này..."), text: $comment, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(3...6)
                    .padding(12)
                    .background(AppColors.base(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Preview bài gốc (rút gọn)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        AvatarView(user: post.sharedPost?.author ?? post.author, size: 28)
                        Text((post.sharedPost?.author ?? post.author).name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    let previewText = post.sharedPost?.content ?? post.content
                    if !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(previewText)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .lineLimit(4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                )

                if shareFailed {
                    Text("Chia sẻ thất bại, thử lại nhé", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding(16)
            .background(AppColors.surface(colorScheme))
            .navigationTitle(bundle.loc("Chia sẻ bài viết"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Huỷ")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await share() }
                    } label: {
                        if isSharing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Chia sẻ", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(isSharing)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func share() async {
        isSharing = true
        shareFailed = false
        defer { isSharing = false }
        do {
            // Backend tự trỏ về bài gốc nếu post này cũng là một bài share
            _ = try await repository.sharePost(
                postId: post.id,
                content: comment.trimmingCharacters(in: .whitespaces),
                mode: appState.currentMode
            )
            onShared?()
            dismiss()
        } catch {
            shareFailed = true
        }
    }
}
