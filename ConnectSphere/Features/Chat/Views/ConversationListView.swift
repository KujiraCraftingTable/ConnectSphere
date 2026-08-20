import SwiftUI

struct ConversationListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    @State private var viewModel = ConversationListViewModel()
    @State private var activeRoute: ActiveChatRoute?

    var body: some View {
        VStack(spacing: 0) {
            // Hàng bạn bè đang active — bấm để nhảy thẳng vào hội thoại
            if !viewModel.activeConnections.isEmpty {
                activeConnectionsBar
                Divider()
            }

            Group {
                if viewModel.isLoading && viewModel.conversations.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Messages"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $activeRoute) { route in
            ChatView(
                conversationId: route.conversationId,
                otherUserId: route.userId,
                otherUserName: route.name,
                otherUserAvatarColor: route.avatarColor,
                otherUserLocation: route.location,
                currentUserId: appState.currentUser?.id ?? "",
                token: appState.authToken ?? ""
            )
        }
        .onAppear {
            guard let token = appState.authToken else { return }
            let mode = appState.currentMode.rawValue
            viewModel.connectSocket(token: token)
            viewModel.registerNewMessageHandler(mode: mode, token: token)
            viewModel.registerPresenceHandlers()
            Task { await viewModel.load(mode: mode, token: token) }
            Task { await viewModel.loadConnections(mode: mode) }
        }
        .onDisappear {
            viewModel.unregisterHandlers()
        }
    }

    // MARK: - Active connections bar

    private var activeConnectionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(viewModel.activeConnections) { conn in
                    Button {
                        openActiveChat(conn)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: conn.user.avatarColor))
                                        .frame(width: 56, height: 56)
                                    Text(String(conn.user.displayName.prefix(1)))
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                // Chấm xanh báo online
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 2))
                            }

                            Text(conn.user.displayName)
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(AppColors.surface(colorScheme))
    }

    /// Mở (hoặc tạo) hội thoại với một kết nối đang active, rồi điều hướng sang ChatView.
    private func openActiveChat(_ conn: ConnectionItemDTO) {
        guard let token = appState.authToken else { return }
        let mode = appState.currentMode.rawValue
        Task {
            guard let convId = try? await viewModel.openConversation(
                with: conn.user.id, mode: mode, token: token
            ) else { return }
            activeRoute = ActiveChatRoute(
                conversationId: convId,
                userId: conn.user.id,
                name: conn.user.displayName,
                avatarColor: conn.user.avatarColor,
                location: conn.user.location
            )
        }
    }

    // MARK: - Conversation list

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.conversations) { conversation in
                    NavigationLink {
                        ChatView(
                            conversationId: conversation.id,
                            otherUserId: conversation.otherUserId,
                            otherUserName: conversation.displayName,
                            otherUserAvatarColor: conversation.otherUserAvatarColor,
                            currentUserId: appState.currentUser?.id ?? "",
                            token: appState.authToken ?? ""
                        )
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            currentUserId: appState.currentUser?.id ?? ""
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No conversations yet", bundle: bundle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("Start a conversation by visiting someone's profile.", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let conversation: Conversation
    let currentUserId: String
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color(hex: conversation.otherUserAvatarColor))
                    .frame(width: 52, height: 52)
                Text(String(conversation.displayName.prefix(1)))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }

            // Name + preview
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.displayName)
                        .font(.system(size: 15, weight: conversation.hasUnread ? .semibold : .regular))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)

                    Spacer()

                    if let at = conversation.lastMessageAt {
                        Text(at.relativeShort(bundle: bundle))
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                }

                HStack {
                    Text(conversation.previewText(currentUserId: currentUserId))
                        .font(.system(size: 13))
                        .foregroundColor(conversation.hasUnread
                                         ? AppColors.textPrimary(colorScheme)
                                         : AppColors.textSecondary(colorScheme))
                        .lineLimit(1)

                    Spacer()

                    if conversation.hasUnread {
                        Text("\(conversation.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: "#1877F2")))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.surface(colorScheme))
    }
}

// MARK: - Active chat navigation route

/// Đích điều hướng khi bấm vào một bạn bè đang active trên hàng trên cùng.
struct ActiveChatRoute: Identifiable, Hashable {
    let conversationId: String
    let userId: String
    let name: String
    let avatarColor: String
    let location: String?

    var id: String { conversationId }
}

// MARK: - Date helper

private extension Date {
    func relativeShort(bundle: Bundle = .main) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(self)
        if diff < 60 { return bundle.loc("just now") }
        if diff < 3600 { return String(format: bundle.loc("%d min"), Int(diff / 60)) }
        if diff < 86400 { return formatted(.dateTime.hour().minute()) }
        if diff < 604800 { return formatted(.dateTime.weekday(.abbreviated)) }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
