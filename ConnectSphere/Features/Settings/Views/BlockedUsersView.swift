import SwiftUI

/// List of users the current user has blocked, with an inline unblock button.
struct BlockedUsersView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = BlockedUsersViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.blockedUsers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError = viewModel.loadError, viewModel.blockedUsers.isEmpty {
                errorState(loadError)
            } else if viewModel.blockedUsers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.blockedUsers) { user in
                        row(user)
                            .listRowBackground(AppColors.surface(colorScheme))
                    }
                }
                .listStyle(.plain)
                .animation(.default, value: viewModel.blockedUsers.map(\.id))
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Blocked users"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    // MARK: - Rows

    private func row(_ user: BlockedUserDTO) -> some View {
        HStack(spacing: 12) {
            avatar(user)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(user.blockedAt.timeAgoString)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            Button {
                Task { await viewModel.unblock(user) }
            } label: {
                if viewModel.unblockingIds.contains(user.id) {
                    ProgressView().scaleEffect(0.7)
                        .frame(width: 70, height: 28)
                } else {
                    Text("Unblock", bundle: bundle)
                        .scaledFont(13, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(themeManager.theme.primary.opacity(0.12)))
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.unblockingIds.contains(user.id))
        }
        .padding(.vertical, 4)
    }

    /// Real image if available, falling back to the first letter (same idea as AvatarView
    /// but takes a BlockedUserDTO instead of a UserProfile).
    private func avatar(_ user: BlockedUserDTO) -> some View {
        ZStack {
            Circle().fill(Color(hex: user.avatarColor ?? "#7F5AF0"))
            Text(String(user.displayName.prefix(1)))
                .scaledFont(17, .bold)
                .foregroundColor(.white)
            if let url = APIConfig.mediaURL(user.avatarUrl) {
                RemoteImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "nosign")
                .scaledFont(40)
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("No blocked users", bundle: bundle)
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .scaledFont(38)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .scaledFont(14)
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) { Task { await viewModel.load() } }
                .scaledFont(14, .semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
