import SwiftUI

/// The current user's connections: pending requests (accept/decline inline)
/// and already-connected people (tap to open their profile).
struct ConnectionsListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = ConnectionsListViewModel()

    var body: some View {
        List {
            // ── Received requests ──────────────────────────────────────────────
            if !viewModel.pendingRequests.isEmpty {
                Section(bundle.loc("Connection request")) {
                    ForEach(viewModel.pendingRequests) { item in
                        HStack(spacing: 12) {
                            userRow(item.user)
                            Spacer()
                            if viewModel.processingIds.contains(item.connectionId) {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button {
                                    Task { await viewModel.respond(item, accept: true, mode: appState.currentMode) }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(themeManager.theme.primary)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    Task { await viewModel.respond(item, accept: false, mode: appState.currentMode) }
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

            // ── Connected ───────────────────────────────────────────────────
            Section(bundle.loc("Friends")) {
                if viewModel.friends.isEmpty && !viewModel.isLoading {
                    Text("No connections yet, try searching and sending a request", bundle: bundle)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else {
                    ForEach(viewModel.friends) { item in
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
        .task { await viewModel.load(mode: appState.currentMode) }
        .refreshable { await viewModel.load(mode: appState.currentMode) }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
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
                if appState.currentMode == .work, let title = user.jobTitle, !title.isEmpty {
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
}
