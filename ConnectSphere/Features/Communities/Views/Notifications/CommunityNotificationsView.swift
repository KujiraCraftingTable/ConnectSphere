import SwiftUI

/// Target điều hướng khi bấm một thông báo — mở community liên quan
private struct CommunityNavTarget: Identifiable, Hashable {
    let id: String
}

/// Displays community notifications for the current user.
/// Navigates to the relevant community on tap.
struct CommunityNotificationsView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: NotificationsViewModel
    @State private var detailTarget: CommunityNavTarget?

    private let token: String

    init(token: String) {
        self.token = token
        _viewModel = State(initialValue: NotificationsViewModel(token: token))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.notifications.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.notifications.isEmpty {
                emptyState
            } else {
                notificationList
            }
        }
        .navigationTitle(bundle.loc("Community Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.unreadCount > 0 {
                    Button(bundle.loc("Mark all read")) {
                        Task<Void, Never>(name: nil) { await viewModel.markAllAsRead() }
                    }
                    .font(.system(size: 14))
                }
            }
        }
        .navigationDestination(item: $detailTarget) { target in
            CommunityDetailView(communityId: target.id, token: token)
                .environment(appState)
        }
        .task {
            await viewModel.fetchNotifications(reset: true)
            await viewModel.fetchUnreadCount()
        }
        .refreshable { await viewModel.fetchNotifications(reset: true) }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var notificationList: some View {
        List {
            ForEach(viewModel.notifications) { notification in
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.markAsRead(notification.id) }
                    detailTarget = CommunityNavTarget(id: notification.communityId)
                } label: {
                    notificationRow(notification)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    notification.isRead
                        ? Color.clear
                        : AppColors.elevated(colorScheme)
                )
                .task { await loadMoreIfNeeded(notification) }
            }
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    private func notificationRow(_ notification: CommunityNotification) -> some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: notification.iconName)
                .font(.system(size: 16))
                .foregroundColor(.purple)
                .frame(width: 36, height: 36)
                .background(Color.purple.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.displayText)
                    .font(.system(size: 14, weight: notification.isRead ? .regular : .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)

                Text(notification.createdAt.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }

            Spacer()

            if !notification.isRead {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadMoreIfNeeded(_ notification: CommunityNotification) async {
        guard let last = viewModel.notifications.last, last.id == notification.id else { return }
        await viewModel.fetchNotifications()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No notifications yet", bundle: bundle)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Community activity will appear here", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
