import SwiftUI

struct ConversationListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    @State private var viewModel = ConversationListViewModel()

    var body: some View {
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
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Tin nhắn"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            guard let token = appState.authToken else { return }
            let mode = appState.currentMode.rawValue
            viewModel.connectSocket(token: token)
            viewModel.registerNewMessageHandler(mode: mode, token: token)
            Task { await viewModel.load(mode: mode, token: token) }
        }
        .onDisappear {
            viewModel.unregisterHandlers()
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
                            otherUserName: conversation.otherUserName,
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
            Text("Chưa có cuộc trò chuyện nào", bundle: bundle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("Bắt đầu trò chuyện bằng cách vào trang cá nhân của ai đó.", bundle: bundle)
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
                Text(String(conversation.otherUserName.prefix(1)))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }

            // Name + preview
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.otherUserName)
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

// MARK: - Date helper

private extension Date {
    func relativeShort(bundle: Bundle = .main) -> String {
        let now = Date()
        let diff = now.timeIntervalSince(self)
        if diff < 60 { return bundle.loc("vừa xong") }
        if diff < 3600 { return String(format: bundle.loc("%d phút"), Int(diff / 60)) }
        if diff < 86400 { return formatted(.dateTime.hour().minute()) }
        if diff < 604800 { return formatted(.dateTime.weekday(.abbreviated)) }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
