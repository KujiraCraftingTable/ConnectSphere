import SwiftUI

/// Push-able destinations on `ProfileView`'s `NavigationStack`, addressable by
/// the AI assistant's navigation actions (`MainTabView
/// .consumePendingAssistantNavigation`) via the same `navPath.append`/
/// `navigationDestination(for:)` mechanism the community deep link already
/// uses. These are purely additive alongside the existing manual-tap
/// `NavigationLink`s in `SettingsView`/`PrivacySecurityView` (e.g. Blocked
/// Users is still also reachable by tapping through Privacy & Security as
/// before) — both push mechanisms coexist safely on the same stack.
enum ProfileRoute: Hashable {
    case settings
    case privacySecurity
    case blockedUsers
    case notificationSettings
}

struct ProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = ProfileViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreatePost = false
    @State private var showEditProfile = false

    /// Binding from MainTabView — resets to root whenever the tab is reselected
    @Binding var navPath: NavigationPath

    private var user: UserProfile {
        viewModel.user ?? appState.currentUser ?? MockData.currentUser
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(spacing: 8) {
                    profileHeader
                    statsRow
                    infoSection
                    postsSection
                }
            }
            .background(AppColors.base(colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    AvatarView(user: user, size: 32)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 6) {
                        Button { showCreatePost = true } label: {
                            navIconButton(icon: "plus.square")
                        }
                        Button { navPath.append(ProfileRoute.settings) } label: {
                            navIconButton(icon: "line.3.horizontal")
                        }
                    }
                }
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView().environment(appState).environment(themeManager)
                case .privacySecurity:
                    PrivacySecurityView().environment(appState).environment(themeManager)
                case .blockedUsers:
                    BlockedUsersView().environment(appState).environment(themeManager)
                case .notificationSettings:
                    NotificationSettingsView().environment(appState).environment(themeManager)
                }
            }
            .sheet(isPresented: $showCreatePost) {
                CreatePostView(onPostCreated: { _ in
                    // Reload the profile after posting
                    if let userId = appState.currentUser?.id {
                        Task { await viewModel.load(userId: userId, mode: appState.currentMode.rawValue) }
                    }
                })
                .environment(appState)
            }
            .sheet(isPresented: $showEditProfile) {
                EditProfileView(onSaved: { updated in
                    viewModel.user = updated
                })
                .environment(appState)
                .environment(themeManager)
            }
            .task {
                if let userId = appState.currentUser?.id {
                    await viewModel.load(userId: userId, mode: appState.currentMode.rawValue)
                }
                consumePendingAssistantSheet()
            }
            .onChange(of: appState.pendingAssistantSheet) { _, _ in
                consumePendingAssistantSheet()
            }
            .onChange(of: appState.currentMode) { _, newMode in
                if let userId = appState.currentUser?.id {
                    Task { await viewModel.load(userId: userId, mode: newMode.rawValue) }
                }
            }
        }
    }

    /// Opens Edit Profile when the AI assistant's "edit profile" guidance
    /// action landed here — mirrors the consume-then-clear pattern
    /// `pendingDeepLink`/`pendingAssistantNavigation` use elsewhere.
    private func consumePendingAssistantSheet() {
        guard appState.pendingAssistantSheet == .editProfile else { return }
        appState.pendingAssistantSheet = nil
        showEditProfile = true
    }

    // MARK: Profile Header (cover + avatar)

    private var profileHeader: some View {
        ZStack(alignment: .bottomLeading) {
            // Cover photo — real image if available, otherwise fall back to a gradient
            CoverPhotoView(coverUrl: user.coverUrl)

            // Avatar overlapping cover
            HStack(alignment: .bottom) {
                AvatarView(user: user, size: 90)
                    .overlay(Circle().stroke(Color.white, lineWidth: 4))
                    .offset(y: 45)
                    .padding(.leading, 16)
                Spacer()
                // Edit profile button
                Button { showEditProfile = true } label: {
                    Text("Edit profile", bundle: bundle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1.5)
                        )
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        .padding(.bottom, 50)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: Stats

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(user.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            if appState.currentMode == .work,
               let title = user.jobTitle, let company = user.company {
                Text("\(title) · \(company)")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            } else {
                Text(user.bio)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            HStack(spacing: 20) {
                statItem(count: user.postCount, label: bundle.loc("Posts"))
                // Tapping the connections stat opens the friends list + pending requests
                NavigationLink {
                    ConnectionsListView()
                } label: {
                    statItem(count: user.connectionCount,
                             label: appState.currentMode == .hobby
                                 ? bundle.loc("Friends") : bundle.loc("Connections"))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.surface(colorScheme))
    }

    private func statItem(count: Int, label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    // MARK: Info Section (skills or interests)

    @ViewBuilder
    private var infoSection: some View {
        if appState.currentMode == .work {
            skillsSection
        } else {
            interestsSection
        }
    }

    private var skillsSection: some View { tagSection(title: bundle.loc("Skills"), items: user.skills) }
    private var interestsSection: some View { tagSection(title: bundle.loc("Interests"), items: user.interests) }

    private func tagSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .appFont(.headline)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(items, id: \.self) { item in
                        Chip(text: item, style: .neutral)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.lg)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: Posts Section

    @ViewBuilder
    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Posts", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if !viewModel.isLoading {
                    Text("\(viewModel.posts.count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if viewModel.isLoading && viewModel.posts.isEmpty {
                ProgressView().padding(.top, 20).frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 5) {
                    ForEach(viewModel.posts) { post in
                        PostCard(
                            post: post,
                            disableSelfNavigation: true,
                            onPostDeleted: { viewModel.removePost(id: post.id) },
                            onPostUpdated: { updated in viewModel.updatePost(updated) }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                                radius: 4, x: 0, y: 2)
                        .padding(.horizontal, 10)
                        .onAppear {
                            if post.id == viewModel.posts.last?.id {
                                Task {
                                    await viewModel.loadMorePosts(userId: user.id, mode: appState.currentMode.rawValue)
                                }
                            }
                        }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView().padding(.vertical, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    private func navIconButton(icon: String) -> some View {
        ZStack {
            Circle().fill(AppColors.elevated(colorScheme)).frame(width: 34, height: 34)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
    }
}
