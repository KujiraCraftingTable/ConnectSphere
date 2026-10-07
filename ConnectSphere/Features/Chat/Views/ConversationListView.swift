import SwiftUI

struct ConversationListView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    /// Created and owned by `MainTabView` so the conversation survives this
    /// sheet being dismissed. Optional because it is built in MainTabView's
    /// `.task`, after first render.
    @Environment(AssistantViewModel.self) private var assistantViewModel: AssistantViewModel?

    @State private var viewModel = ConversationListViewModel()
    @State private var activeRoute: ChatRoute?
    @State private var showAssistantChat = false

    // Search (name + message content, across all conversations) + read/unread filter
    @State private var searchQuery = ""
    @State private var unreadOnly = false

    // "New group" flow: pick members, then (optionally) name the group, then
    // navigate straight into the freshly-created group's ChatView.
    @State private var showGroupMemberPicker = false
    @State private var pendingGroupMemberIds: Set<String> = []
    @State private var showNewGroupDetails = false
    @State private var isCreatingGroup = false
    @State private var createGroupError: String?

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Active friends row — tap to jump straight into the conversation.
            // Hidden while searching so the results list has full room.
            if !viewModel.activeConnections.isEmpty && !isSearchActive {
                activeConnectionsBar
            }

            if !isSearchActive {
                unreadFilterRow
            }

            Group {
                if isSearchActive {
                    searchResultsList
                } else if viewModel.isLoading && viewModel.conversations.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error, viewModel.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 38))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text(error)
                            .font(.system(size: 14))
                            .multilineTextAlignment(.center)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(.horizontal, 32)
                        Button(bundle.loc("Retry")) {
                            Task { await viewModel.load(mode: appState.currentMode.rawValue,
                                                        token: appState.authToken ?? "") }
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleConversations.isEmpty {
                    if unreadOnly {
                        unreadEmptyState
                    } else {
                        emptyState
                    }
                } else {
                    conversationList
                }
            }
        }
        .background(AppColors.base(colorScheme))
        // The AI assistant lives here and nowhere else — it is a
        // messaging-adjacent helper, not an app-wide overlay. No bottom-bar
        // padding is needed because this screen hides the tab bar below.
        .overlay(alignment: .bottomTrailing) {
            if assistantViewModel != nil {
                AssistantLauncherButton { showAssistantChat = true }
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showAssistantChat) {
            if let assistantViewModel {
                AssistantChatView(
                    appState: appState,
                    themeManager: themeManager,
                    viewModel: assistantViewModel
                )
                .environment(appState)
                .environment(themeManager)
            }
        }
        .navigationTitle(bundle.loc("Messages"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search chats and messages", bundle: bundle))
        .onChange(of: searchQuery) { _, newValue in
            viewModel.search(query: newValue, mode: appState.currentMode.rawValue, token: appState.authToken ?? "")
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showGroupMemberPicker = true } label: {
                    Image(systemName: "person.3.fill")
                }
            }
        }
        .navigationDestination(item: $activeRoute) { route in
            ChatView(
                conversationId: route.conversationId,
                peer: route.peer,
                otherUserLocation: route.location,
                currentUserId: appState.currentUser?.id ?? "",
                token: appState.authToken ?? "",
                initialJumpMessageId: route.jumpToMessageId
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
        .sheet(isPresented: $showGroupMemberPicker) {
            GroupMemberPickerView(
                excludedUserIds: [],
                remainingSlots: 99, // 100-member cap minus the creator
                confirmTitle: bundle.loc("Next"),
                onConfirm: { ids in
                    pendingGroupMemberIds = ids
                    showNewGroupDetails = true
                }
            )
            .environment(appState)
        }
        .sheet(isPresented: $showNewGroupDetails) {
            NewGroupDetailsSheet(
                memberCount: pendingGroupMemberIds.count,
                isCreating: isCreatingGroup,
                onCreate: { name in
                    Task { await createGroup(name: name) }
                }
            )
        }
        .alert(bundle.loc("Error"), isPresented: .constant(createGroupError != nil)) {
            Button(bundle.loc("OK")) { createGroupError = nil }
        } message: {
            Text(createGroupError ?? "")
        }
    }

    // MARK: - New group creation

    private func createGroup(name: String) async {
        guard let token = appState.authToken, !isCreatingGroup else { return }
        isCreatingGroup = true
        defer { isCreatingGroup = false }
        let mode = appState.currentMode.rawValue
        do {
            let convId = try await viewModel.createGroup(
                memberIds: Array(pendingGroupMemberIds), mode: mode,
                name: name.isEmpty ? nil : name, token: token
            )
            showNewGroupDetails = false
            pendingGroupMemberIds = []
            activeRoute = ChatRoute(
                conversationId: convId,
                peer: .group(name: name.isEmpty ? bundle.loc("Group") : name, avatarUrl: nil, avatarColor: nil,
                             memberCount: pendingGroupMemberIds.count + 1),
                location: nil
            )
        } catch {
            createGroupError = friendlyError(error)
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
                                // Green dot indicating online status
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .cardStyle()
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, AppSpacing.sm)
    }

    /// Open (or create) a conversation with an active connection, then navigate to ChatView.
    private func openActiveChat(_ conn: ConnectionItemDTO) {
        guard let token = appState.authToken else { return }
        let mode = appState.currentMode.rawValue
        Task {
            guard let convId = try? await viewModel.openConversation(
                with: conn.user.id, mode: mode, token: token
            ) else { return }
            activeRoute = ChatRoute(
                conversationId: convId,
                peer: .direct(otherUserId: conn.user.id, name: conn.user.displayName,
                              avatarColor: conn.user.avatarColor, avatarUrl: conn.user.avatarUrl),
                location: conn.user.location
            )
        }
    }

    // MARK: - Read/unread filter

    // Same visual language as FeedView's `feedScopeButton` ("For you"/"Connections")
    // pill so this reads as the same control pattern across the app.
    private var unreadFilterRow: some View {
        HStack(spacing: 8) {
            unreadFilterButton(false, label: bundle.loc("All"))
            unreadFilterButton(true, label: bundle.loc("Unread"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private func unreadFilterButton(_ value: Bool, label: String) -> some View {
        let isActive = unreadOnly == value
        return Button {
            unreadOnly = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isActive ? themeManager.theme.primary : AppColors.surface(colorScheme), in: Capsule())
                .overlay(
                    Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: isActive ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// `viewModel.conversations` filtered by the read/unread toggle — purely
    /// client-side, `Conversation.hasUnread` already comes with the list.
    private var visibleConversations: [Conversation] {
        viewModel.conversations.filter { !unreadOnly || $0.hasUnread }
    }

    // MARK: - Conversation list

    private var conversationList: some View {
        ScrollView {
            roundedRows(visibleConversations) { conversation in
                NavigationLink {
                    ChatView(
                        conversationId: conversation.id,
                        peer: ChatPeer(conversation),
                        currentUserId: appState.currentUser?.id ?? "",
                        token: appState.authToken ?? ""
                    )
                } label: {
                    ConversationRow(
                        conversation: conversation,
                        currentUserId: appState.currentUser?.id ?? "",
                        accentColor: themeManager.theme.primary
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Rows inside one rounded card (8 pt side margins like the post cards),
    /// with hairline dividers that start after the avatar, iMessage-style.
    private func roundedRows<Item: Identifiable, Row: View>(
        _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    Divider().padding(.leading, ConversationRow.textInset)
                }
            }
        }
        .cardStyle()
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: - Search (name + message content)

    private var searchResultsList: some View {
        Group {
            if viewModel.isSearching && viewModel.searchResults.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchResults.isEmpty {
                searchEmptyState
            } else {
                ScrollView {
                    roundedRows(viewModel.searchResults) { hit in
                        Button { openSearchHit(hit) } label: {
                            ConversationRow(
                                conversation: hit.conversation,
                                currentUserId: appState.currentUser?.id ?? "",
                                accentColor: themeManager.theme.primary,
                                previewOverride: hit.matchType == "message"
                                    ? highlighted(hit.matchedSnippet ?? "", term: searchQuery)
                                    : nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No results", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bolds + tints every case-insensitive occurrence of `term` in `text` —
    /// same pattern as `ChatMessageSearchView.highlighted(_:term:)`.
    private func highlighted(_ text: String, term: String) -> AttributedString {
        var attr = AttributedString(text)
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let found = attr[searchRange].range(of: needle, options: .caseInsensitive) {
            attr[found].foregroundColor = themeManager.theme.primary
            attr[found].inlinePresentationIntent = .stronglyEmphasized
            searchRange = found.upperBound..<attr.endIndex
        }
        return attr
    }

    private func openSearchHit(_ hit: ConversationSearchHit) {
        activeRoute = ChatRoute(
            conversationId: hit.conversation.id,
            peer: ChatPeer(hit.conversation),
            location: nil,
            jumpToMessageId: hit.matchedMessageId
        )
    }

    // MARK: - Empty state

    private var unreadEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No unread chats", bundle: bundle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.currentMode == .hobby ? "face.smiling" : "bubble.left.and.bubble.right")
                .font(.system(size: 52))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(appState.currentMode == .hobby
                 ? bundle.loc("No chats yet 👋")
                 : bundle.loc("No conversations yet"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(appState.currentMode == .hobby
                 ? bundle.loc("Say hi to a connection and start the fun!")
                 : bundle.loc("Start a conversation by visiting someone's profile."))
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
    let accentColor: Color
    /// Search results show the matched message (highlighted) here instead of
    /// the conversation's actual last-message preview.
    var previewOverride: AttributedString? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    var body: some View {
        HStack(spacing: 12) {
            avatar

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
                    if conversation.isGroup {
                        Text(String(format: bundle.loc("%d members"), conversation.memberCount))
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }

                    Text(previewOverride ?? AttributedString(conversation.previewText(currentUserId: currentUserId)))
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
                            .background(Capsule().fill(accentColor))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())   // the card behind supplies the surface colour
    }

    /// Where the name/preview column starts (padding + avatar + spacing) —
    /// dividers between rows start here.
    static let textInset: CGFloat = 16 + 52 + 12

    @ViewBuilder
    private var avatar: some View {
        if conversation.isGroup {
            ZStack {
                Circle()
                    .fill(Color(hex: conversation.avatarColor))
                    .frame(width: 52, height: 52)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
        } else {
            ZStack {
                Circle()
                    .fill(Color(hex: conversation.avatarColor))
                    .frame(width: 52, height: 52)
                Text(String(conversation.displayName.prefix(1)))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Chat navigation route

/// Navigation target used by any flow that jumps straight into a
/// conversation's `ChatView` from outside its row (active connections bar,
/// freshly-created group).
struct ChatRoute: Identifiable, Hashable {
    let conversationId: String
    let peer: ChatPeer
    let location: String?
    /// Set when navigating from a search hit — `ChatView` scrolls to and
    /// highlights this message once it opens.
    var jumpToMessageId: String? = nil

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
