import SwiftUI

/// Danh sách user mình đang chặn, kèm nút bỏ chặn tại chỗ.
struct BlockedUsersView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var blockedUsers: [BlockedUserDTO] = []
    @State private var isLoading = false
    @State private var unblockingIds: Set<String> = []

    private let userRepo = UserRepository()

    var body: some View {
        Group {
            if isLoading && blockedUsers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blockedUsers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(blockedUsers) { user in
                        row(user)
                            .listRowBackground(AppColors.surface(colorScheme))
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Blocked users"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Rows

    private func row(_ user: BlockedUserDTO) -> some View {
        HStack(spacing: 12) {
            avatar(user)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(user.blockedAt.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            Button {
                Task { await unblock(user) }
            } label: {
                if unblockingIds.contains(user.id) {
                    ProgressView().scaleEffect(0.7)
                        .frame(width: 70, height: 28)
                } else {
                    Text("Unblock", bundle: bundle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(themeManager.theme.primary.opacity(0.12)))
                }
            }
            .buttonStyle(.plain)
            .disabled(unblockingIds.contains(user.id))
        }
        .padding(.vertical, 4)
    }

    /// Avatar ảnh thật nếu có, fallback chữ cái đầu (giống AvatarView
    /// nhưng nhận BlockedUserDTO thay vì UserProfile).
    private func avatar(_ user: BlockedUserDTO) -> some View {
        ZStack {
            Circle().fill(Color(hex: user.avatarColor ?? "#7F5AF0"))
            Text(String(user.displayName.prefix(1)))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
            if let urlStr = user.avatarUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
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
                .font(.system(size: 40))
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("No blocked users", bundle: bundle)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let users = try? await userRepo.fetchBlockedUsers() {
            blockedUsers = users
        }
    }

    private func unblock(_ user: BlockedUserDTO) async {
        unblockingIds.insert(user.id)
        defer { unblockingIds.remove(user.id) }
        do {
            try await userRepo.unblockUser(userId: user.id)
            withAnimation { blockedUsers.removeAll { $0.id == user.id } }
        } catch {
            // Giữ nguyên row; user có thể thử lại
        }
    }
}
