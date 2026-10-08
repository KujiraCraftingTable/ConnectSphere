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
    @State private var spacesViewModel = SpacesViewModel()
    @State private var activeRoute: ChatRoute?
    @State private var showAssistantChat = false

    // Search (name + message content, across all conversations)
    @State private var searchQuery = ""

    /// Spaces view on/off — a per-device preference, not account data.
    @AppStorage("chatSpacesView") private var spacesOn = false
    /// Set once Spaces has been switched on; until then a one-line hint under
    /// the switch says what it is.
    @AppStorage("chatSpacesIntroSeen") private var spacesIntroSeen = false
    /// Ids of folded space sections ("others" for Other chats), comma-joined.
    @AppStorage("chatCollapsedSpaces") private var collapsedRaw = ""

    // Spaces sheets
    @State private var spaceEditor: SpaceEditorTarget?
    @State private var peoplePickerSpace: ChatSpace?
    @State private var pendingDeleteSpace: ChatSpace?

    // Swipe actions
    @State private var moreActionsFor: Conversation?
    @State private var pendingDelete: Conversation?
    @State private var pendingBlock: Conversation?

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var mode: String { appState.currentMode.rawValue }
    private var token: String { appState.authToken ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            // Active friends row — tap to jump straight into the conversation.
            // Hidden while searching so the results list has full room.
            if !viewModel.activeConnections.isEmpty && !isSearchActive {
                activeConnectionsBar
            }

            if !isSearchActive {
                spacesBar
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
                            Task { await viewModel.load(mode: mode, token: token) }
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.inbox.isEmpty && !(spacesOn && !spacesViewModel.spaces.isEmpty) {
                    if spacesOn {
                        ScrollView { SpacesIntroCard { spaceEditor = .create } }
                    } else {
                        emptyState
                    }
                } else {
                    inboxList
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
            viewModel.search(query: newValue, mode: mode, token: token)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $activeRoute) { route in
            ChatView(
                conversationId: route.conversationId,
                peer: route.peer,
                otherUserLocation: route.location,
                currentUserId: appState.currentUser?.id ?? "",
                token: token,
                initialJumpMessageId: route.jumpToMessageId
            )
        }
        .onAppear {
            guard let authToken = appState.authToken else { return }
            viewModel.connectSocket(token: authToken)
            viewModel.registerNewMessageHandler(mode: mode, token: authToken)
            viewModel.registerPresenceHandlers()
            Task { await viewModel.load(mode: mode, token: authToken) }
            Task { await viewModel.loadConnections(mode: mode) }
            Task { await spacesViewModel.load(mode: mode, token: authToken) }
        }
        .onDisappear {
            viewModel.unregisterHandlers()
        }
        // A group made from a 1-on-1 chat's settings opens here.
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { note in
            guard let route = note.object as? ChatRoute else { return }
            activeRoute = route
            Task { await viewModel.load(mode: mode, token: token) }
        }
        .onChange(of: spacesOn) { _, on in if on { spacesIntroSeen = true } }
        .sheet(item: $spaceEditor) { target in spaceEditorSheet(target) }
        .sheet(item: $peoplePickerSpace) { space in
            SpacePeoplePickerView(
                spaceName: space.name,
                candidates: SpaceCandidate.merge(conversations: viewModel.conversations, connections: viewModel.connections),
                initialSelection: space.memberIds
            ) { ids in
                await spacesViewModel.setMembers(space, to: ids, token: token)
            }
        }
        .confirmationDialog(moreActionsFor?.displayName ?? "", isPresented: Binding(
            get: { moreActionsFor != nil }, set: { if !$0 { moreActionsFor = nil } }
        ), titleVisibility: .visible, presenting: moreActionsFor) { conversation in
            moreActions(conversation)
        }
        .alert(bundle.loc("Delete this chat?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { conversation in
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await viewModel.delete(conversation, token: token) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Its messages are removed for you only. It comes back if a new message arrives.", bundle: bundle)
        }
        .alert(String(format: bundle.loc("Block %@?"), pendingBlock?.displayName ?? ""), isPresented: Binding(
            get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }
        ), presenting: pendingBlock) { conversation in
            Button(bundle.loc("Block"), role: .destructive) {
                Task { await viewModel.block(conversation) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("They won't be able to message you or see your profile.", bundle: bundle)
        }
        .alert(bundle.loc("Delete space?"), isPresented: Binding(
            get: { pendingDeleteSpace != nil }, set: { if !$0 { pendingDeleteSpace = nil } }
        ), presenting: pendingDeleteSpace) { space in
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await spacesViewModel.delete(space, token: token) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { space in
            Text(String(format: bundle.loc("“%@” is removed. Your chats with its people stay."), space.name))
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.actionError != nil || spacesViewModel.error != nil },
            set: { if !$0 { viewModel.actionError = nil; spacesViewModel.error = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.actionError ?? spacesViewModel.error ?? "")
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

    // MARK: - Spaces bar

    /// Left: the Spaces view switch and the Archive button. Right (Spaces on): "+ New space".
    private var spacesBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppSpacing.sm) {
                Toggle(isOn: $spacesOn.animation(.snappy)) {
                    Label {
                        Text("Spaces", bundle: bundle)
                    } icon: {
                        SpacePlanetIcon(color: themeManager.theme.primary, size: 18)
                    }
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                        .fixedSize()
                }
                .toggleStyle(LeadingSwitchStyle(tint: themeManager.theme.primary))

                NavigationLink {
                    ArchivedChatsView(viewModel: viewModel, onOpen: open)
                } label: {
                    inboxButtonLabel(icon: "archivebox")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(bundle.loc("Archived chats")))

                NavigationLink {
                    WaitingChatsView(viewModel: viewModel, onOpen: open)
                } label: {
                    inboxButtonLabel(icon: "tray.full")
                        .overlay(alignment: .topTrailing) {
                            if !viewModel.waiting.isEmpty {
                                Text("\(viewModel.waiting.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .padding(.horizontal, viewModel.waiting.count > 9 ? 3 : 0)
                                    .background(AppColors.danger(colorScheme), in: Capsule())
                                    .offset(x: 6, y: -7)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: bundle.loc("Waiting, %lld"), viewModel.waiting.count)))

                Spacer()

                if spacesOn {
                    // A round "+" rather than a labelled pill: with the switch,
                    // Archive and Waiting there's no room for words on a phone.
                    Button { spaceEditor = .create } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(themeManager.theme.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(bundle.loc("New space")))
                    .transition(.opacity.combined(with: .scale))
                }
            }
            if !spacesOn && !spacesIntroSeen && spacesViewModel.hasLoaded && spacesViewModel.spaces.isEmpty {
                Text("New: keep chats in Spaces — folders for the people you talk to.", bundle: bundle)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        // Feed's scope row sits 12 pt inside an 8 pt-inset stack — same here,
        // so the controls line up with the cards' content instead of their edges.
        .padding(.horizontal, AppSpacing.sm + 12)
        .padding(.top, AppSpacing.sm)
    }

    private func inboxButtonLabel(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppColors.surface(colorScheme), in: Capsule())
            .overlay(Capsule().stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
    }

    // MARK: - Conversation list

    /// Inset-grouped `List` (rounded cards like the rest of the app) so each
    /// row gets native swipe actions. Spaces off: one card. Spaces on: a card
    /// per space, then "Other chats".
    private var inboxList: some View {
        List {
            if spacesOn {
                if spacesViewModel.spaces.isEmpty {
                    SpacesIntroCard { spaceEditor = .create }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ForEach(SpaceSection.make(conversations: viewModel.inbox, spaces: spacesViewModel.spaces)) { section in
                    if case .space(let space) = section.kind {
                        spaceFolder(section, space: space)
                    } else {
                        Section {
                            if !isCollapsed(section.id) {
                                ForEach(section.conversations) { conversationRow($0, showSpaces: false) }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(viewModel.inbox) { conversationRow($0, showSpaces: true) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, AppSpacing.sm, for: .scrollContent)
        .listSectionSpacing(AppSpacing.md)
        .refreshable {
            await viewModel.load(mode: mode, token: token)
            await spacesViewModel.load(mode: mode, token: token)
        }
    }

    private func conversationRow(_ conversation: Conversation, showSpaces: Bool, folder: FolderSlot? = nil) -> some View {
        Button { open(conversation) } label: {
            ConversationRow(
                conversation: conversation,
                currentUserId: appState.currentUser?.id ?? "",
                accentColor: themeManager.theme.primary,
                spaces: showSpaces ? conversation.otherUserId.map(spacesViewModel.spaces(containing:)) ?? [] : []
            )
        }
        .buttonStyle(.plain)
        .inFolder(folder, surface: AppColors.surface(colorScheme))
        .alignmentGuide(.listRowSeparatorLeading) { _ in ConversationRow.textInset }
        // Order matters: the first button sits at the edge and is the one a
        // full (strong) swipe triggers — Archive.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await viewModel.setArchived(conversation, true, token: token) }
            } label: {
                Label(bundle.loc("Archive"), systemImage: "archivebox.fill")
            }
            .tint(.indigo)
            Button {
                Task { await viewModel.setPinned(conversation, !conversation.isPinned, token: token) }
            } label: {
                Label(bundle.loc(conversation.isPinned ? "Unpin" : "Pin"),
                      systemImage: conversation.isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
            Button { moreActionsFor = conversation } label: {
                Label(bundle.loc("More"), systemImage: "ellipsis.circle.fill")
            }
            .tint(.gray)
        }
    }

    @ViewBuilder
    private func moreActions(_ conversation: Conversation) -> some View {
        if conversation.hasUnread {
            Button(bundle.loc("Mark as read")) {
                Task { await viewModel.markRead(conversation, token: token) }
            }
        }
        Button(bundle.loc(conversation.isMuted ? "Unmute" : "Mute")) {
            Task { await viewModel.setMuted(conversation, !conversation.isMuted, token: token) }
        }
        if !conversation.isGroup {
            Button(bundle.loc("Block"), role: .destructive) { pendingBlock = conversation }
        }
        Button(bundle.loc("Delete"), role: .destructive) { pendingDelete = conversation }
    }

    // MARK: - Space sections

    private var collapsedIds: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func isCollapsed(_ id: String) -> Bool { collapsedIds.contains(id) }

    private func toggleCollapsed(_ id: String) {
        var ids = collapsedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        withAnimation(.snappy) { collapsedRaw = ids.sorted().joined(separator: ",") }
    }

    private func sectionHeader(_ section: SpaceSection) -> some View {
        let collapsed = isCollapsed(section.id)
        return HStack(spacing: 8) {
            Button { toggleCollapsed(section.id) } label: {
                HStack(spacing: 8) {
                    switch section.kind {
                    case .space(let space):
                        SpacePlanetIcon(color: space.color.color, size: 18)
                        Text(space.name)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    case .others:
                        Text("Other chats", bundle: bundle)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    Text("\(section.rows.count)")
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                    // Folded: still say there's something new inside.
                    if collapsed && section.unreadCount > 0 {
                        Text("\(section.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(themeManager.theme.primary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(collapsed ? bundle.loc("Expand") : bundle.loc("Collapse")))

            if case .space(let space) = section.kind {
                Menu {
                    Button { spaceEditor = .edit(space) } label: {
                        Label(bundle.loc("Edit name & colour"), systemImage: "pencil")
                    }
                    Button { peoplePickerSpace = space } label: {
                        Label(bundle.loc("Edit people"), systemImage: "person.2")
                    }
                    Button(role: .destructive) { pendingDeleteSpace = space } label: {
                        Label(bundle.loc("Delete space"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(String(format: bundle.loc("%@ options"), space.name)))
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .textCase(nil)
    }

    /// One space drawn as a coloured folder: its header and a white card of
    /// rows sit on a soft wash of the space's colour, which shows as a margin
    /// all round the card — the colour is the layer the chats rest on.
    @ViewBuilder
    private func spaceFolder(_ section: SpaceSection, space: ChatSpace) -> some View {
        let tint = space.color.color.opacity(colorScheme == .dark ? 0.22 : 0.14)
        let rows = section.rows
        Section {
            sectionHeader(section)
                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 10))
                .listRowBackground(tint)
                .listRowSeparator(.hidden)
            if !isCollapsed(section.id) {
                if rows.isEmpty {
                    addPeopleRow(space)
                        .inFolder(FolderSlot(tint: tint, isFirst: true, isLast: true), surface: AppColors.surface(colorScheme))
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    let slot = FolderSlot(tint: tint, isFirst: index == 0, isLast: index == rows.count - 1)
                    switch row {
                    case .chat(let conversation):
                        conversationRow(conversation, showSpaces: false, folder: slot)
                    case .person(let member):
                        personRow(member, in: space, folder: slot)
                    }
                }
            }
        }
    }

    /// Someone in the space you haven't messaged yet: tap to start the chat.
    private func personRow(_ member: SpaceMember, in space: ChatSpace, folder: FolderSlot) -> some View {
        Button { openChat(with: member) } label: {
            HStack(spacing: 12) {
                Avatar(name: member.displayName, colorHex: member.avatarColor, imageURL: member.avatarUrl, diameter: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.displayName)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    Text("No messages yet — say hi", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "bubble.left")
                    .font(.system(size: 15))
                    .foregroundColor(space.color.color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .inFolder(folder, surface: AppColors.surface(colorScheme))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await spacesViewModel.setMembership(of: member.id, in: space, isMember: false, token: token) }
            } label: {
                Label(bundle.loc("Remove from space"), systemImage: "minus.circle.fill")
            }
        }
    }

    /// A space nobody's in yet.
    private func addPeopleRow(_ space: ChatSpace) -> some View {
        Button { peoplePickerSpace = space } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .foregroundColor(space.color.color)
                Text("Add people", bundle: bundle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(themeManager.theme.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openChat(with member: SpaceMember) {
        Task {
            guard let id = try? await viewModel.openConversation(with: member.id, mode: mode, token: token) else { return }
            activeRoute = ChatRoute(
                conversationId: id,
                peer: .direct(otherUserId: member.id, name: member.displayName,
                              avatarColor: member.avatarColor ?? AppColors.avatarFallback,
                              avatarUrl: member.avatarUrl),
                location: nil)
        }
    }

    // MARK: - Space sheets

    @ViewBuilder
    private func spaceEditorSheet(_ target: SpaceEditorTarget) -> some View {
        switch target {
        case .create:
            SpaceEditorSheet(title: bundle.loc("New space"), confirmTitle: bundle.loc("Next"),
                             isSaving: spacesViewModel.isSaving) { name, color in
                guard let space = await spacesViewModel.create(name: name, color: color, memberIds: [],
                                                               mode: mode, token: token) else { return false }
                spacesOn = true
                // Straight on to choosing its people, once this sheet has gone.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    peoplePickerSpace = space
                }
                return true
            }
        case .edit(let space):
            SpaceEditorSheet(title: bundle.loc("Edit space"), confirmTitle: bundle.loc("Save"),
                             initialName: space.name, initialColor: space.color,
                             isSaving: spacesViewModel.isSaving) { name, color in
                await spacesViewModel.update(space, name: name, color: color, token: token)
            }
        }
    }

    private func open(_ conversation: Conversation) {
        activeRoute = ChatRoute(conversationId: conversation.id, peer: ChatPeer(conversation), location: nil)
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

struct ConversationRow: View {
    let conversation: Conversation
    let currentUserId: String
    let accentColor: Color
    /// Search results show the matched message (highlighted) here instead of
    /// the conversation's actual last-message preview.
    var previewOverride: AttributedString? = nil
    /// This person's spaces, shown as small tags in the flat (Spaces off) list.
    var spaces: [ChatSpace] = []
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

                    ForEach(spaces.prefix(2)) { space in
                        SpaceTag(space: space)
                    }

                    Spacer()

                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
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

    /// The person's (or group's) photo when there is one, else initials or the
    /// group icon on their colour.
    @ViewBuilder
    private var avatar: some View {
        switch conversation.peer {
        case .direct(_, _, let name, let color, let url, _, _):
            Avatar(name: name, colorHex: color, imageURL: url, diameter: 52)
        case .group(_, let url, _, _):
            if let url, !url.isEmpty {
                Avatar(name: conversation.displayName, colorHex: conversation.avatarColor, imageURL: url, diameter: 52)
            } else {
                ZStack {
                    Circle()
                        .fill(Color(hex: conversation.avatarColor))
                        .frame(width: 52, height: 52)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
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
