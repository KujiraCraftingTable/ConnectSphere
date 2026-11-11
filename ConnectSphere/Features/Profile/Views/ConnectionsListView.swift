import SwiftUI

/// The current user's connections: requests received (accept/decline inline),
/// requests sent (cancel inline) and already-connected people (tap to open
/// their profile). Hobby says "friends", Work says "connections".
struct ConnectionsListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = ConnectionsListViewModel()
    /// The sent request waiting on "Unsend?" confirmation.
    @State private var unsending: ConnectionItemDTO?

    private var isHobby: Bool { appState.currentMode == .hobby }

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
                                        .scaledFont(28)
                                        .foregroundColor(themeManager.theme.primary)
                                }
                                .accessibilityLabel(Bundle.app.loc("Accept"))
                                .buttonStyle(.plain)
                                Button {
                                    Task { await viewModel.respond(item, accept: false, mode: appState.currentMode) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(28)
                                        .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.5))
                                }
                                .accessibilityLabel(Bundle.app.loc("Decline"))
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // ── Sent requests ──────────────────────────────────────────────────
            if !viewModel.sentRequests.isEmpty {
                Section(bundle.loc(isHobby ? "Friend requests sent" : "Connection requests sent")) {
                    ForEach(viewModel.sentRequests) { item in
                        HStack(spacing: 12) {
                            NavigationLink {
                                UserProfileView(userId: item.user.id, preloadedUser: item.user.toUserProfile())
                            } label: {
                                userRow(item.user)
                            }
                            if viewModel.processingIds.contains(item.connectionId) {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Button(bundle.loc("Cancel")) { unsending = item }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(AppColors.textSecondary(colorScheme))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // ── Connected ───────────────────────────────────────────────────
            Section(bundle.loc(isHobby ? "Friends" : "Connections")) {
                if viewModel.friends.isEmpty && !viewModel.isLoading {
                    Text(isHobby ? "No friends yet, try searching and sending a request"
                                 : "No connections yet, try searching and sending a request", bundle: bundle)
                        .scaledFont(14)
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
        // A list you go into from a profile, like Settings: no tab bar over it.
        .toolbar(.hidden, for: .tabBar)
        .task { await viewModel.load(mode: appState.currentMode) }
        .refreshable { await viewModel.load(mode: appState.currentMode) }
        .alert(bundle.loc(isHobby ? "Unsend friend request?" : "Withdraw connection request?"),
               isPresented: Binding(get: { unsending != nil }, set: { if !$0 { unsending = nil } })) {
            Button(bundle.loc(isHobby ? "Unsend" : "Withdraw"), role: .destructive) {
                if let item = unsending {
                    Task { await viewModel.cancel(item, mode: appState.currentMode) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
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
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if appState.currentMode == .work, let title = user.jobTitle, !title.isEmpty {
                    Text(user.company.map { "\(title) · \($0)" } ?? title)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if let location = user.location, !location.isEmpty {
                    Text(location)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        }
    }
}
