import SwiftUI

/// Someone as they appear in one community. Opened from "..." › Your
/// community profile, a poster or commenter's name/photo, or the members list.
struct CommunityMemberProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    let userId: String
    @State private var viewModel: CommunityMemberProfileViewModel
    @State private var detailRoute: PostRoute?
    @State private var pull: CGFloat = 0

    private let communityId: String

    init(communityId: String, userId: String) {
        self.communityId = communityId
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
                            .scaledFont(14)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .padding(.top, 30)
                    }
                    ForEach(viewModel.posts) { post in
                        PostCard(post: post,
                                 onPostDeleted: { viewModel.removePost(id: post.id) },
                                 onOpenDetail: { focus in detailRoute = PostRoute(postId: post.id, focusComposer: focus) },
                                 insideCommunityId: communityId)
                            .cardStyle()
                            .padding(.horizontal, AppSpacing.sm)
                            .task { if post.id == viewModel.posts.last?.id { await viewModel.loadMore(token: token) } }
                    }
                }
                if viewModel.isLoading { ProgressView().padding() }
            }
            .padding(.bottom, AppSpacing.lg)
        }
        // The cover runs up under the status bar; its fade keeps it legible.
        .ignoresSafeArea(edges: .top)
        .trackPull($pull)
        .refreshable { await viewModel.refresh(token: token) }
        .overlay(alignment: .top) { PullRefreshIndicator(pull: pull, isRefreshing: viewModel.isRefreshing) }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await viewModel.load(token: token) }
        .navigationDestination(isPresented: Binding(get: { detailRoute != nil }, set: { if !$0 { detailRoute = nil } })) {
            if let route = detailRoute { PostDetailView(postId: route.postId, focusComposer: route.focusComposer) }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(get: { viewModel.errorMessage != nil },
                                                          set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    /// Laid out like a profile's header (`ProfileHeaderCard`): the same cover
    /// and floating card, holding what this community knows about them.
    private func header(_ p: CommunityMemberProfile) -> some View {
        CoverHeader(coverUrl: p.coverUrl) {
            VStack(spacing: 12) {
                Avatar(name: p.displayName, colorHex: p.avatarColor, imageURL: p.avatarUrl, diameter: 132)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, -66)

                VStack(spacing: 4) {
                    Text(p.displayName)
                        .scaledFont(26, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .multilineTextAlignment(.center)
                    Text("@\(p.username)")
                        .scaledFont(15)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    if let line = membershipLine(p) {
                        Text(line)
                            .scaledFont(14)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }

                HStack(spacing: 0) {
                    stat(p.postCount, bundle.loc("posts here"))
                    stat(p.connectionsCount, bundle.loc("connections"))
                }
                .padding(.vertical, 4)

                NavigationLink {
                    UserProfileView(userId: userId).environment(appState)
                } label: {
                    Text("View full profile", bundle: bundle)
                        .scaledFont(15, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.sm + 2)
                        .background(themeManager.theme.primary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
            .frame(maxWidth: .infinity)
            .background(AppColors.surface(colorScheme),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: AppElevation.overlay.color(colorScheme), radius: AppElevation.overlay.radius,
                    y: AppElevation.overlay.y)
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)")
                .scaledFont(18, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(label)
                .scaledFont(12)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
