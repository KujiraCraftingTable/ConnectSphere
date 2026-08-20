import SwiftUI

/// Danh sách kết nối của mình: lời mời đang chờ (accept/decline tại chỗ)
/// và những người đã kết nối (bấm vào mở hồ sơ).
struct ConnectionsListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var pendingRequests: [ConnectionItemDTO] = []
    @State private var friends: [ConnectionItemDTO] = []
    @State private var isLoading = false
    @State private var processingIds: Set<String> = []
    @State private var errorMessage: String?

    private let repository = ConnectionRepository()

    var body: some View {
        List {
            // ── Lời mời đã nhận ──────────────────────────────────────────────
            if !pendingRequests.isEmpty {
                Section(bundle.loc("Connection request")) {
                    ForEach(pendingRequests) { item in
                        HStack(spacing: 12) {
                            userRow(item.user)
                            Spacer()
                            if processingIds.contains(item.connectionId) {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button {
                                    Task { await respond(item, accept: true) }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(themeManager.theme.primary)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    Task { await respond(item, accept: false) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // ── Đã kết nối ───────────────────────────────────────────────────
            Section(bundle.loc("Friends")) {
                if friends.isEmpty && !isLoading {
                    Text("No connections yet — try searching and sending a request", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else {
                    ForEach(friends) { item in
                        NavigationLink {
                            UserProfileView(userId: item.user.id, preloadedUser: item.user.toUserProfile())
                        } label: {
                            userRow(item.user)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Connect"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(bundle.loc("Error"), isPresented: .constant(errorMessage != nil)) {
            Button(bundle.loc("OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Rows

    private func userRow(_ user: ConnectionUserDTO) -> some View {
        HStack(spacing: 10) {
            AvatarView(user: user.toUserProfile(), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if let title = user.jobTitle, !title.isEmpty {
                    Text(user.company.map { "\(title) · \($0)" } ?? title)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if let location = user.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let mode = appState.currentMode.rawValue
        async let pending = repository.fetchConnections(mode: mode, status: "pending_received")
        async let accepted = repository.fetchConnections(mode: mode, status: "accepted")
        pendingRequests = (try? await pending) ?? []
        friends         = (try? await accepted) ?? []
    }

    private func respond(_ item: ConnectionItemDTO, accept: Bool) async {
        processingIds.insert(item.connectionId)
        defer { processingIds.remove(item.connectionId) }
        do {
            if accept {
                try await repository.accept(connectionId: item.connectionId)
            } else {
                try await repository.decline(connectionId: item.connectionId)
            }
            await load()
        } catch {
            // Giữ nguyên danh sách; báo lỗi để user biết và thử lại
            errorMessage = friendlyError(error)
        }
    }
}
