import SwiftUI

/// Sheet for sharing (reposting) a post to your own wall, with an optional message.
struct SharePostSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    let post: Post
    var onShared: (() -> Void)? = nil

    @State private var viewModel = SharePostViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField(bundle.loc("Say something about this post..."), text: $viewModel.comment, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(3...6)
                    .padding(12)
                    .background(AppColors.base(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Preview of the original post (condensed)
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

                if viewModel.shareFailed {
                    Text("Couldn't share, please try again", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding(16)
            .background(AppColors.surface(colorScheme))
            .navigationTitle(bundle.loc("Share post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                        guard await viewModel.share(postId: post.id, mode: appState.currentMode) else { return }
                        onShared?()
                        dismiss()
                    }
                    } label: {
                        if viewModel.isSharing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Share", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isSharing)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
