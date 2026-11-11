import SwiftUI

/// Followers / Following of a profile in the current mode.
struct FollowListView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel: FollowListViewModel

    init(userId: String, showsFollowers: Bool) {
        _viewModel = State(initialValue: FollowListViewModel(userId: userId, showsFollowers: showsFollowers))
    }

    var body: some View {
        List {
            if viewModel.people.isEmpty && !viewModel.isLoading {
                Text(viewModel.errorMessage
                     ?? bundle.loc(viewModel.showsFollowers ? "No followers yet" : "Not following anyone yet"))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            } else {
                ForEach(viewModel.people, id: \.id) { person in
                    NavigationLink {
                        UserProfileView(userId: person.id, preloadedUser: person.toUserProfile())
                    } label: {
                        row(person)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if viewModel.isLoading && viewModel.people.isEmpty { ProgressView() } }
        .navigationTitle(bundle.loc(viewModel.showsFollowers ? "Followers" : "Following"))
        .navigationBarTitleDisplayMode(.inline)
        // Like Friends/Connections: a list you go into, no tab bar over it.
        .toolbar(.hidden, for: .tabBar)
        .task { await viewModel.load(mode: appState.currentMode) }
        .refreshable { await viewModel.load(mode: appState.currentMode) }
    }

    private func row(_ person: ConnectionUserDTO) -> some View {
        HStack(spacing: 10) {
            AvatarView(user: person.toUserProfile(), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if appState.currentMode == .work, let title = person.jobTitle, !title.isEmpty {
                    Text(person.company.map { "\(title) · \($0)" } ?? title)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if let location = person.location, !location.isEmpty {
                    Text(location)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        }
    }
}
