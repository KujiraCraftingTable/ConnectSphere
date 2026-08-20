import SwiftUI

// MARK: - NotificationsView

/// Target điều hướng khi bấm vào một thông báo kết nối
private struct ProfileNavTarget: Identifiable, Hashable {
    let id: String
}

/// Target điều hướng khi bấm vào thông báo like/comment
private struct PostNavTarget: Identifiable, Hashable {
    let id: String
}

struct NotificationsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var notifications: [UserNotificationDTO] = []
    @State private var isLoading = false
    @State private var navTarget: ProfileNavTarget?
    @State private var postNavTarget: PostNavTarget?

    private let notifRepo = UserNotificationRepository()

    /// Gợi ý AI (mode mismatch) — hiển thị card có nút xử lý
    private var aiNotifications: [UserNotificationDTO] {
        notifications.filter { $0.type == "mode_mismatch" }
    }

    /// Thông báo kết nối — bấm vào mở hồ sơ người gửi
    private var connectionNotifications: [UserNotificationDTO] {
        notifications.filter {
            ["connection_request", "connection_accepted"].contains($0.type)
        }
    }

    /// Hoạt động trên bài viết (like/comment/reply/share) — bấm vào mở bài viết
    private var activityNotifications: [UserNotificationDTO] {
        notifications.filter {
            ["post_liked", "post_commented", "comment_replied", "post_shared"].contains($0.type)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── AI notifications (mode mismatch, etc.) ────────────────────
                if !aiNotifications.isEmpty {
                    Section(bundle.loc("AI suggestions")) {
                        ForEach(aiNotifications) { notif in
                            ModeMismatchCard(notif: notif) { action in
                                await handleResolve(notif: notif, action: action)
                            }
                            .listRowBackground(
                                notif.isRead
                                    ? AppColors.surface(colorScheme)
                                    : Color.orange.opacity(0.06)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                }

                // ── Activity notifications (like / comment / reply) ──────────
                if !activityNotifications.isEmpty {
                    Section(bundle.loc("Activity")) {
                        ForEach(activityNotifications) { notif in
                            Button {
                                openPost(from: notif)
                            } label: {
                                ActorNotifRow(notif: notif)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                notif.isRead
                                    ? AppColors.surface(colorScheme)
                                    : themeManager.theme.primary.opacity(0.06)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                }

                // ── Connection notifications ──────────────────────────────────
                if !connectionNotifications.isEmpty {
                    Section(bundle.loc("Connect")) {
                        ForEach(connectionNotifications) { notif in
                            Button {
                                openProfile(from: notif)
                            } label: {
                                ActorNotifRow(notif: notif)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                notif.isRead
                                    ? AppColors.surface(colorScheme)
                                    : themeManager.theme.primary.opacity(0.06)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                }

                if !isLoading && aiNotifications.isEmpty
                    && connectionNotifications.isEmpty && activityNotifications.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 40))
                            .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
                        Text("No notifications yet", bundle: bundle)
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Notifications"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await markAllRead() }
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 18))
                            .foregroundColor(themeManager.theme.primary)
                    }
                }
            }
            .navigationDestination(item: $navTarget) { target in
                UserProfileView(userId: target.id)
            }
            .navigationDestination(item: $postNavTarget) { target in
                PostDetailView(postId: target.id)
            }
            .task {
                await loadNotifications()
                // Refresh danh sách ngay khi có notification realtime
                WebSocketClient.shared.on("notification", tag: "notificationsView") { _ in
                    Task { @MainActor in await loadNotifications() }
                }
            }
            .onDisappear {
                WebSocketClient.shared.off("notification", tag: "notificationsView")
            }
            .refreshable { await loadNotifications() }
        }
    }

    // MARK: - Private

    private func loadNotifications() async {
        guard let token = appState.authToken else { return }
        isLoading = true
        defer { isLoading = false }
        if let response = try? await notifRepo.fetchAll(token: token) {
            notifications = response.data
        }
    }

    private func markAllRead() async {
        guard let token = appState.authToken else { return }
        try? await notifRepo.markAllRead(token: token)
        await loadNotifications()
    }

    /// Đánh dấu đã đọc rồi mở hồ sơ người gửi lời mời
    private func openProfile(from notif: UserNotificationDTO) {
        guard let userId = notif.payload.fromUserId else { return }
        markReadLocally(notif)
        navTarget = ProfileNavTarget(id: userId)
    }

    /// Đánh dấu đã đọc rồi mở bài viết liên quan
    private func openPost(from notif: UserNotificationDTO) {
        guard let postId = notif.postId else { return }
        markReadLocally(notif)
        postNavTarget = PostNavTarget(id: postId)
    }

    private func markReadLocally(_ notif: UserNotificationDTO) {
        if !notif.isRead, let token = appState.authToken {
            Task { try? await notifRepo.markRead(notificationId: notif.id, token: token) }
        }
    }

    private func handleResolve(notif: UserNotificationDTO, action: String) async {
        guard let token = appState.authToken else { return }
        try? await notifRepo.resolve(notificationId: notif.id, action: action, token: token)
        await loadNotifications()
    }
}

// MARK: - ActorNotifRow

/// Row dùng chung cho mọi notification "ai đó đã làm gì":
/// kết nối, like, comment, reply. Icon và câu chữ đổi theo type.
struct ActorNotifRow: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    let notif: UserNotificationDTO

    private var senderName: String {
        notif.payload.fromDisplayName ?? bundle.loc("Someone")
    }

    private var message: String {
        switch notif.type {
        case "connection_request":
            return String(format: bundle.loc("%@ sent you a connection request"), senderName)
        case "connection_accepted":
            return String(format: bundle.loc("%@ accepted your connection request"), senderName)
        case "post_liked":
            return String(format: bundle.loc("%@ liked your post"), senderName)
        case "post_commented":
            if let excerpt = notif.payload.excerpt, !excerpt.isEmpty {
                return String(format: bundle.loc("%@ commented: “%@”"), senderName, excerpt)
            }
            return String(format: bundle.loc("%@ commented on your post"), senderName)
        case "comment_replied":
            if let excerpt = notif.payload.excerpt, !excerpt.isEmpty {
                return String(format: bundle.loc("%@ replied to your comment: “%@”"), senderName, excerpt)
            }
            return String(format: bundle.loc("%@ replied to your comment"), senderName)
        case "post_shared":
            return String(format: bundle.loc("%@ shared your post"), senderName)
        default:
            return senderName
        }
    }

    private var badgeIcon: String {
        switch notif.type {
        case "connection_request":  return "person.badge.plus"
        case "connection_accepted": return "person.badge.shield.checkmark"
        case "post_liked":          return "hand.thumbsup.fill"
        case "post_commented":      return "bubble.left.fill"
        case "comment_replied":     return "arrowshape.turn.up.left.fill"
        case "post_shared":         return "arrowshape.turn.up.right.fill"
        default:                    return "bell.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                senderAvatar
                ZStack {
                    Circle().fill(themeManager.theme.primary).frame(width: 20, height: 20)
                    Image(systemName: badgeIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notif.createdAt.timeAgoString)
                    .font(.system(size: 13))
                    .foregroundColor(notif.isRead
                                     ? AppColors.textSecondary(colorScheme)
                                     : themeManager.theme.primary)
            }

            Spacer()

            if !notif.isRead {
                Circle().fill(themeManager.theme.primary).frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var senderAvatar: some View {
        if let urlString = notif.payload.fromAvatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initialCircle
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            initialCircle
        }
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: notif.payload.fromAvatarColor ?? "#1877F2"))
                .frame(width: 52, height: 52)
            Text(String(senderName.prefix(1)).uppercased())
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - ModeMismatchCard

struct ModeMismatchCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let notif: UserNotificationDTO
    let onAction: (String) async -> Void

    @State private var showKeepConfirm   = false
    @State private var showSwitchConfirm = false
    @State private var isResolving = false

    private var suggestedLabel: String {
        notif.payload.suggestedMode == "hobby" ? bundle.loc("Hobby") : bundle.loc("Work")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                Text("AI suggestion", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
                Text(notif.createdAt.timeAgoString)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                if !notif.isRead {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                }
            }

            // Reason text
            Text(notif.payload.reason ?? String(format: bundle.loc("This post may fit %@ mode better"), suggestedLabel))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            // Action buttons (hidden after resolved)
            if notif.resolvedAt == nil && !isResolving {
                HStack(spacing: 10) {
                    Button(bundle.loc("Keep")) {
                        showKeepConfirm = true
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                    )

                    Button(String(format: bundle.loc("Switch to %@"), suggestedLabel)) {
                        showSwitchConfirm = true
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.orange))
                }
            } else if isResolving {
                ProgressView().scaleEffect(0.8)
            } else {
                Text("Resolved", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.vertical, 8)
        .confirmationDialog(
            bundle.loc("Keep the current mode?"),
            isPresented: $showKeepConfirm,
            titleVisibility: .visible
        ) {
            Button(bundle.loc("Keep"), role: .destructive) {
                Task {
                    isResolving = true
                    await onAction("keep")
                    isResolving = false
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("The post will stay in the current mode.", bundle: bundle)
        }
        .confirmationDialog(
            String(format: bundle.loc("Switch to %@ mode?"), suggestedLabel),
            isPresented: $showSwitchConfirm,
            titleVisibility: .visible
        ) {
            Button(String(format: bundle.loc("Switch to %@"), suggestedLabel)) {
                Task {
                    isResolving = true
                    await onAction("switch")
                    isResolving = false
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: bundle.loc("The post will be moved to %@ mode."), suggestedLabel))
        }
    }
}
