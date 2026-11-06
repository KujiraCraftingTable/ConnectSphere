import SwiftUI

/// "..." › Pending posts (admins and moderators).
struct PendingPostsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    @State private var viewModel: PendingPostsViewModel
    @State private var declining: Post?
    @State private var declineReason = ""

    init(communityId: String) {
        _viewModel = State(initialValue: PendingPostsViewModel(communityId: communityId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.md) {
                if viewModel.posts.isEmpty && !viewModel.isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal").scaledFont(36)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text("No posts waiting for approval", bundle: bundle)
                            .scaledFont(15).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.top, 60)
                }
                ForEach(viewModel.posts) { post in
                    VStack(spacing: 8) {
                        PostCard(post: post).cardStyle()
                        HStack(spacing: 10) {
                            Button { declining = post; declineReason = "" } label: {
                                Text("Decline", bundle: bundle).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(AppColors.danger(colorScheme))
                            Button { Task { await viewModel.review(post, approve: true, reason: nil, token: token) } } label: {
                                Text("Approve", bundle: bundle).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(themeManager.theme.primary)
                        }
                        .disabled(viewModel.reviewing.contains(post.id))
                    }
                }
                if viewModel.isLoading { ProgressView().padding() }
            }
            .padding(AppSpacing.sm)
        }
        .appBackground()
        .navigationTitle(bundle.loc("Pending posts"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .alert(bundle.loc("Decline this post?"), isPresented: Binding(get: { declining != nil },
                                                                     set: { if !$0 { declining = nil } })) {
            TextField(bundle.loc("Reason (optional)"), text: $declineReason)
            Button(bundle.loc("Decline"), role: .destructive) {
                if let post = declining {
                    Task { await viewModel.review(post, approve: false, reason: declineReason, token: token) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("The author will see it as declined, with your reason.", bundle: bundle)
        }
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }
}
