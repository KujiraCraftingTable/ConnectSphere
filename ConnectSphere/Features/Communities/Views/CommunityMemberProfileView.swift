import SwiftUI

/// Someone as they appear in one community — opened from "..." › Your
/// community profile, a poster or commenter's name/photo, or the members list.
struct CommunityMemberProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    let userId: String
    @State private var viewModel: CommunityMemberProfileViewModel
    @State private var detailRoute: PostRoute?

    init(communityId: String, userId: String) {
        self.userId = userId
        _viewModel = State(initialValue: CommunityMemberProfileViewModel(communityId: communityId, userId: userId))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: AppSpacing.sm) {
                if let p = viewModel.profile {
                    header(p)
                    if viewModel.posts.isEmpty && !viewModel.isLoading {
                        Text("No posts in this community yet", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .padding(.top, 30)
                    }
                    ForEach(viewModel.posts) { post in
                        PostCard(post: post,
                                 onPostDeleted: { viewModel.removePost(id: post.id) },
                                 onOpenDetail: { focus in detailRoute = PostRoute(postId: post.id, focusComposer: focus) })
                            .cardStyle()
                            .padding(.horizontal, AppSpacing.sm)
                            .task { if post.id == viewModel.posts.last?.id { await viewModel.loadMore(token: token) } }
                    }
                }
                if viewModel.isLoading { ProgressView().padding() }
            }
            .padding(.bottom, AppSpacing.lg)
        }
        .appBackground()
        .navigationTitle(viewModel.profile?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .navigationDestination(isPresented: Binding(get: { detailRoute != nil }, set: { if !$0 { detailRoute = nil } })) {
            if let route = detailRoute { PostDetailView(postId: route.postId, focusComposer: route.focusComposer) }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    private func header(_ p: CommunityMemberProfile) -> some View {
        VStack(spacing: 0) {
            CoverArtwork(coverUrl: p.coverUrl)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()
            VStack(spacing: 6) {
                Avatar(name: p.displayName, colorHex: p.avatarColor, imageURL: p.avatarUrl, diameter: 88)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 4))
                    .padding(.top, -44)
                Text(p.displayName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(p.username)")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                HStack(spacing: 14) {
                    stat(p.connectionsCount, bundle.loc("connections"))
                    stat(p.postCount, bundle.loc("posts here"))
                }
                .padding(.top, 4)
                if let line = membershipLine(p) {
                    Text(line)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                NavigationLink {
                    UserProfileView(userId: userId).environment(appState)
                } label: {
                    Text("View full profile", bundle: bundle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
            .frame(maxWidth: .infinity)
            .background(AppColors.surface(colorScheme))
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.system(size: 15, weight: .bold))
            Text(label).font(.system(size: 14)).foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    /// "Admin · Joined 4 August 2024".
    private func membershipLine(_ p: CommunityMemberProfile) -> String? {
        guard let joined = p.joinedAt else { return nil }
        let date = String(format: bundle.loc("Joined %@"), joined.formatted(date: .long, time: .omitted))
        switch p.role {
        case "admin": return bundle.loc("Admin") + " · " + date
        case "moderator": return bundle.loc("Moderator") + " · " + date
        default: return date
        }
    }
}
