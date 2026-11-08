import SwiftUI

/// Settings screen for a single conversation, opened by tapping the header/avatar
/// in `ChatView`. 1:1: shared nickname, other person's profile, shared chat theme,
/// media, search, mute, block, clear. Group: group name/photo (owner-only) +
/// participants management, in place of the nickname/profile pills; block toggle
/// is hidden (no single target, per-member block still reachable via each
/// member's profile from `GroupParticipantsView`).
struct ChatSettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    let conversationId: String
    let peer: ChatPeer
    let token: String
    var onCleared: () -> Void = {}
    /// Selecting a search result. The sheet closes itself then tells ChatView to jump to the message
    var onJumpToMessage: (String) -> Void = { _ in }
    /// Fires after a successful block/unblock so `ChatView` can react (disable input, show notice).
    /// 1:1 only, the block row is hidden entirely for groups.
    var onBlockStatusChanged: ((Bool) -> Void)? = nil

    @State private var viewModel: ChatSettingsViewModel
    @State private var showNicknameEditor = false
    @State private var nicknameDraft = ""
    @State private var showThemePicker = false
    @State private var showDeleteWarning = false

    // Pin default auto-delete preference (client-side-only convenience,
    // there's no server-side conversation-level default, `expires_at` is
    // per-pin at pin time). Scoped per-conversation via a dynamic key set in `init`.
    @AppStorage private var pinAutoDeleteRaw: String
    @AppStorage private var pinAutoDeleteCustomDateRaw: Double
    // Quick-emoji send: the emoji the send button becomes while the message
    // box is empty, so send is never a greyed-out dead control. Per-conversation,
    // same dynamic-key pattern as the pin default above.
    @AppStorage private var quickEmoji: String
    @State private var showQuickEmojiOptions = false
    @State private var showPinCustomDatePicker = false
    @State private var pinCustomDateDraft = Date()

    // Group-only editors (owner-only actions)
    @State private var showGroupNameEditor = false
    @State private var groupNameDraft = ""
    @State private var showGroupColorPicker = false
    /// Removed symmetrically in `.onDisappear`. Lets `GroupParticipantsView`
    /// (pushed on top of this sheet) tell this screen to close itself too
    /// once the current user leaves the group.
    @State private var leftGroupObserver: NSObjectProtocol?

    @State private var showBlockConfirm = false

    // Spaces (1-on-1 and groups) + "Create group with …" (1-on-1 only)
    @State private var spacesViewModel = SpacesViewModel()
    @State private var showSpaceMembership = false
    @State private var showNewSpaceForPerson = false
    @State private var showGroupPicker = false
    @State private var pendingGroupMemberIds: Set<String> = []
    @State private var showNewGroupDetails = false

    private let groupColorSwatches = [
        "#7F5AF0", "#2CB67D", "#FF8906", "#E53170", "#3DA9FC",
        "#F25F4C", "#8A8F98", "#0F4C5C", "#EF7674", "#5C6BC0",
    ]

    init(conversationId: String, peer: ChatPeer, token: String,
         onCleared: @escaping () -> Void = {},
         onJumpToMessage: @escaping (String) -> Void = { _ in },
         onBlockStatusChanged: ((Bool) -> Void)? = nil) {
        self.conversationId = conversationId
        self.peer = peer
        self.token = token
        self.onCleared = onCleared
        self.onJumpToMessage = onJumpToMessage
        self.onBlockStatusChanged = onBlockStatusChanged
        _viewModel = State(initialValue: ChatSettingsViewModel(conversationId: conversationId, token: token))
        _pinAutoDeleteRaw = AppStorage(
            wrappedValue: PinAutoDeleteOption.never.rawValue,
            pinAutoDeleteStorageKey(conversationId: conversationId)
        )
        _pinAutoDeleteCustomDateRaw = AppStorage(
            wrappedValue: 0,
            pinAutoDeleteCustomDateStorageKey(conversationId: conversationId)
        )
        _quickEmoji = AppStorage(
            wrappedValue: QuickEmoji.defaultValue,
            quickEmojiStorageKey(conversationId: conversationId)
        )
    }

    private var isGroup: Bool { peer.isGroup }
    /// A chat with the official account: no nicknames, pins or blocking on either side.
    private var isSupportChat: Bool { viewModel.settings?.withOfficial ?? false }
    private var displayName: String { viewModel.settings?.displayName ?? peer.name }
    private var isOwner: Bool { viewModel.isOwner(currentUserId: appState.currentUser?.id ?? "") }

    /// Palette currently applied to this conversation (falls back to the global theme).
    private var currentPalette: ThemePalette {
        ThemePalette.byId(viewModel.settings?.theme) ?? themeManager.theme
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    // Not while this chat is still a message request: neither side
                    // can file the other into a space or group them until accepted.
                    if viewModel.settings?.requestState == nil { peopleCard }
                    actionsList
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc(isGroup ? "Group settings" : "Chat settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .task {
            await viewModel.load()
            if !isGroup, let otherId = peer.otherUserId {
                await viewModel.loadBlockStatus(otherUserId: otherId)
            }
            // If I leave the group from the pushed `GroupParticipantsView`,
            // close this sheet too instead of leaving it stranded underneath.
            leftGroupObserver = NotificationCenter.default.addObserver(
                forName: .userLeftGroupConversation, object: nil, queue: .main
            ) { note in
                guard let convId = note.userInfo?["conversationId"] as? String,
                      convId == conversationId else { return }
                dismiss()
            }
        }
        .onDisappear {
            if let leftGroupObserver {
                NotificationCenter.default.removeObserver(leftGroupObserver)
                self.leftGroupObserver = nil
            }
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.blockErrorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.blockErrorMessage = nil }
        } message: {
            Text(viewModel.blockErrorMessage ?? "")
        }
        .alert(bundle.loc("Nickname"), isPresented: $showNicknameEditor) {
            TextField(bundle.loc("Nickname"), text: $nicknameDraft)
            Button(bundle.loc("Save")) { Task { await viewModel.saveNickname(nicknameDraft) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("Set a nickname for this person. Both of you will see it.", bundle: bundle)
        }
        .alert(bundle.loc("Group name"), isPresented: $showGroupNameEditor) {
            TextField(bundle.loc("Group name"), text: $groupNameDraft)
            Button(bundle.loc("Save")) { Task { await viewModel.renameGroup(groupNameDraft) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .alert(bundle.loc("Delete all messages?"), isPresented: $showDeleteWarning) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task {
                    if await viewModel.clearConversation() {
                        onCleared()
                        dismiss()
                    }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This removes every message from your side only. The other person will still see them. This can't be undone.", bundle: bundle)
        }
        .sheet(isPresented: $showQuickEmojiOptions) {
            QuickEmojiPickerSheet(emoji: $quickEmoji)
        }
        .sheet(isPresented: $showThemePicker) { themePickerSheet }
        .sheet(isPresented: $showGroupColorPicker) { groupColorPickerSheet }
        .sheet(isPresented: $showPinCustomDatePicker) { pinCustomDatePickerSheet }
    }

    // MARK: - Header (avatar + nickname/profile, or group name/photo/participants)

    private var header: some View {
        VStack(spacing: 12) {
            avatarLarge

            VStack(spacing: 2) {
                Text(displayName)
                    .scaledFont(20, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if isGroup {
                    Text(String(format: bundle.loc("%d members"), viewModel.settings?.members.count ?? peer.memberCount ?? 0))
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                } else if let settings = viewModel.settings, settings.otherUserNickname != nil {
                    // When a nickname is set, show the real name underneath for context.
                    Text(settings.otherUserName ?? "")
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            HStack(spacing: 12) {
                if isGroup {
                    if isOwner {
                        Button {
                            groupNameDraft = displayName
                            showGroupNameEditor = true
                        } label: {
                            pill(icon: "pencil", title: bundle.loc("Group name"))
                        }
                        .buttonStyle(.plain)

                        Button { showGroupColorPicker = true } label: {
                            pill(icon: "photo", title: bundle.loc("Group photo"))
                        }
                        .buttonStyle(.plain)
                    }

                    NavigationLink {
                        GroupParticipantsView(conversationId: conversationId, token: token)
                    } label: {
                        pill(icon: "person.2", title: bundle.loc("Participants"))
                    }
                    .buttonStyle(.plain)
                } else {
                    if !isSupportChat {
                        Button {
                            nicknameDraft = viewModel.settings?.otherUserNickname ?? ""
                            showNicknameEditor = true
                        } label: {
                            pill(icon: "pencil", title: bundle.loc("Nickname"))
                        }
                        .buttonStyle(.plain)
                    }

                    NavigationLink {
                        UserProfileView(userId: peer.otherUserId ?? "").environment(appState)
                    } label: {
                        pill(icon: "person.crop.circle", title: bundle.loc("Profile"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var avatarLarge: some View {
        Group {
            if isGroup {
                if let urlString = viewModel.settings?.groupAvatarUrl ?? peer.avatarUrl,
                   let url = APIConfig.mediaURL(urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            groupPlaceholder
                        }
                    }
                } else {
                    groupPlaceholder
                }
            } else {
                ZStack {
                    Circle().fill(Color(hex: peer.avatarColor))
                    Text(String(displayName.prefix(1)))
                        .scaledFont(34, .bold)
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(Circle())
    }

    private var groupPlaceholder: some View {
        ZStack {
            Circle().fill(Color(hex: viewModel.settings?.groupAvatarColor ?? peer.avatarColor))
            Image(systemName: "person.3.fill")
                .scaledFont(30, .semibold)
                .foregroundColor(.white)
        }
    }

    private func pill(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .scaledFont(18, .semibold)
                .foregroundColor(themeManager.theme.primary)
            Text(title)
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .frame(width: 104, height: 62)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions list

    // MARK: - Spaces (+ "Create group with …" for a 1-on-1)

    private var chatSpaces: [ChatSpace] {
        isGroup ? spacesViewModel.spaces(containingGroup: conversationId)
                : peer.otherUserId.map(spacesViewModel.spaces(containing:)) ?? []
    }

    private func isInSpace(_ space: ChatSpace) -> Bool {
        isGroup ? space.containsGroup(conversationId) : space.contains(peer.otherUserId ?? "")
    }

    private var peopleCard: some View {
        VStack(spacing: 0) {
            Button { showSpaceMembership = true } label: {
                SettingsRow(icon: "", iconColor: .clear,
                            title: bundle.loc("Spaces"), colorScheme: colorScheme,
                            subtitle: chatSpaces.isEmpty
                                ? bundle.loc("Not in a space yet")
                                : chatSpaces.map(\.name).joined(separator: " · "),
                            showsChevron: true,
                            customIcon: AnyView(SpacePlanetIcon(color: chatSpaces.first?.color.color
                                                                ?? themeManager.theme.primary, size: 24)))
            }
            .buttonStyle(.plain)
            // The official account only replies; it never starts a group.
            if !isGroup && !(appState.currentUser?.isOfficial ?? false) {
                divider
                Button { showGroupPicker = true } label: {
                    SettingsRow(icon: "person.3.fill", iconColor: themeManager.theme.primary,
                                title: String(format: bundle.loc("Create group with %@"), displayName),
                                colorScheme: colorScheme, showsChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .task {
            await spacesViewModel.load(mode: appState.currentMode.rawValue, token: token)
        }
        .sheet(isPresented: $showSpaceMembership) {
            SpaceMembershipSheet(
                name: displayName,
                spaces: spacesViewModel.spaces,
                isIn: isInSpace,
                onToggle: { space, isIn in
                    Task {
                        if isGroup {
                            await spacesViewModel.setGroupMembership(of: conversationId, in: space,
                                                                     isMember: isIn, token: token)
                        } else {
                            await spacesViewModel.setMembership(of: peer.otherUserId ?? "", in: space,
                                                                isMember: isIn, token: token)
                        }
                    }
                },
                onNewSpace: {
                    showSpaceMembership = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        showNewSpaceForPerson = true
                    }
                }
            )
        }
        .sheet(isPresented: $showNewSpaceForPerson) {
            SpaceEditorSheet(title: bundle.loc("New space"), confirmTitle: bundle.loc("Create"),
                             isSaving: spacesViewModel.isSaving) { name, color in
                await spacesViewModel.create(name: name, color: color,
                                             memberIds: isGroup ? [] : [peer.otherUserId ?? ""],
                                             groupIds: isGroup ? [conversationId] : [],
                                             mode: appState.currentMode.rawValue, token: token) != nil
            }
        }
        .sheet(isPresented: $showGroupPicker) {
            GroupMemberPickerView(
                excludedUserIds: Set([peer.otherUserId ?? ""]),
                remainingSlots: 98,  // 100-member cap minus me and this person
                confirmTitle: bundle.loc("Next"),
                minimumSelection: 1,
                note: String(format: bundle.loc("With %@, add at least 1 more person. A group needs 3 people or more."), displayName),
                onConfirm: { ids in
                    pendingGroupMemberIds = ids
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        showNewGroupDetails = true
                    }
                }
            )
            .environment(appState)
        }
        .sheet(isPresented: $showNewGroupDetails) {
            NewGroupDetailsSheet(memberCount: pendingGroupMemberIds.count + 1,
                                 isCreating: viewModel.isCreatingGroup) { name in
                Task { await createGroup(name: name) }
            }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { spacesViewModel.error != nil || viewModel.error != nil },
            set: { if !$0 { spacesViewModel.error = nil; viewModel.error = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(spacesViewModel.error ?? viewModel.error ?? "")
        }
    }

    private func createGroup(name: String) async {
        guard let otherId = peer.otherUserId,
              let id = await viewModel.createGroup(with: otherId, plus: pendingGroupMemberIds,
                                                   name: name.isEmpty ? nil : name,
                                                   mode: appState.currentMode.rawValue) else { return }
        let memberCount = pendingGroupMemberIds.count + 2
        showNewGroupDetails = false
        pendingGroupMemberIds = []
        dismiss()
        // Messages opens the new group in place of this chat.
        NotificationCenter.default.post(name: .openConversation, object: ChatRoute(
            conversationId: id,
            peer: .group(name: name.isEmpty ? bundle.loc("Group") : name, avatarUrl: nil, avatarColor: nil,
                         memberCount: memberCount),
            location: nil))
    }

    private var actionsList: some View {
        VStack(spacing: 0) {
            Button { showThemePicker = true } label: {
                SettingsRow(icon: "paintpalette.fill", iconColor: currentPalette.primary,
                            title: bundle.loc("Chat theme"), colorScheme: colorScheme,
                            trailing: AnyView(
                                Circle().fill(currentPalette.primaryGradient).frame(width: 22, height: 22)
                            ))
            }
            .buttonStyle(.plain)
            divider

            NavigationLink {
                ChatMediaGalleryView(viewModel: viewModel)
            } label: {
                SettingsRow(icon: "photo.on.rectangle.angled", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Photos & videos"), colorScheme: colorScheme, showsChevron: true)
            }
            .buttonStyle(.plain)
            divider

            NavigationLink {
                ChatMessageSearchView(viewModel: viewModel, onSelect: { message in
                    dismiss()
                    onJumpToMessage(message.id)
                })
            } label: {
                SettingsRow(icon: "magnifyingglass", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Search in conversation"), colorScheme: colorScheme, showsChevron: true)
            }
            .buttonStyle(.plain)
            divider

            NavigationLink {
                ChatPinnedMessagesView(viewModel: viewModel, onSelect: { message in
                    dismiss()
                    onJumpToMessage(message.id)
                })
            } label: {
                SettingsRow(icon: "pin.fill", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Pinned messages"), colorScheme: colorScheme, showsChevron: true)
            }
            .buttonStyle(.plain)
            divider

            // Nobody pins in a chat with ConnectSphere.
            if !isSupportChat {
                // Menus, not dialogs: the choices drop down from the row tapped.
                Menu {
                    ForEach(PinAutoDeleteOption.allCases.filter { $0 != .custom }) { option in
                        Button(bundle.loc(option.label)) { pinAutoDeleteRaw = option.rawValue }
                    }
                    Button(bundle.loc("Custom date")) {
                        pinCustomDateDraft = pinAutoDeleteCustomDateRaw > 0
                            ? Date(timeIntervalSince1970: pinAutoDeleteCustomDateRaw)
                            : Date().addingTimeInterval(60 * 60 * 24 * 7)
                        showPinCustomDatePicker = true
                    }
                } label: {
                    SettingsRow(icon: "timer", iconColor: themeManager.theme.primary,
                                title: bundle.loc("Default auto-delete time"), colorScheme: colorScheme,
                                subtitle: pinAutoDeleteSubtitle)
                }
                .buttonStyle(.plain)
                divider
            }

            Button { showQuickEmojiOptions = true } label: {
                SettingsRow(icon: "hand.thumbsup.fill", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Quick emoji"), colorScheme: colorScheme,
                            subtitle: bundle.loc("Sent when the message box is empty"),
                            trailing: AnyView(Text(quickEmoji).scaledFont(22)))
            }
            .buttonStyle(.plain)
            divider

            Menu {
                Button(bundle.loc("For 5 minutes"))  { Task { await viewModel.setMute(minutes: 5) } }
                Button(bundle.loc("For 10 minutes")) { Task { await viewModel.setMute(minutes: 10) } }
                Button(bundle.loc("For 30 minutes")) { Task { await viewModel.setMute(minutes: 30) } }
                Button(bundle.loc("Until I turn it back on")) { Task { await viewModel.setMute(minutes: -1) } }
                if viewModel.isMuted {
                    Button(bundle.loc("Turn on notifications")) { Task { await viewModel.setMute(minutes: nil) } }
                }
            } label: {
                SettingsRow(icon: viewModel.isMuted ? "bell.slash.fill" : "bell.fill",
                            iconColor: themeManager.theme.primary,
                            title: bundle.loc("Mute notifications"), colorScheme: colorScheme,
                            subtitle: muteSubtitle)
            }
            .buttonStyle(.plain)
            divider

            // No single block target from this screen for groups, per-member
            // block is still reachable via each member's profile in
            // `GroupParticipantsView`, using `UserProfileView`'s block flow unchanged.
            if !isGroup && !isSupportChat {
                Button {
                    if viewModel.isBlocked {
                        Task { await toggleBlock() }
                    } else {
                        showBlockConfirm = true
                    }
                } label: {
                    SettingsRow(icon: viewModel.isBlocked ? "person.crop.circle.badge.checkmark" : "nosign",
                                iconColor: viewModel.isBlocked ? themeManager.theme.primary : .red,
                                title: bundle.loc(viewModel.isBlocked ? "Unblock" : "Block user"),
                                colorScheme: colorScheme, destructive: !viewModel.isBlocked)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    bundle.loc("Block this user?"),
                    isPresented: $showBlockConfirm,
                    titleVisibility: .visible
                ) {
                    Button(bundle.loc("Block"), role: .destructive) {
                        Task { await toggleBlock() }
                    }
                    Button(bundle.loc("Cancel"), role: .cancel) {}
                } message: {
                    Text("You two will no longer see each other's posts, all connections will be removed, and you won't be able to message each other.", bundle: bundle)
                }
                divider
            }

            Button { showDeleteWarning = true } label: {
                SettingsRow(icon: "trash.fill", iconColor: .red,
                            title: bundle.loc("Delete all messages"), colorScheme: colorScheme,
                            destructive: true)
            }
            .buttonStyle(.plain)
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Divider().padding(.leading, 56)
    }

    /// 1:1 only. Tells the presenting ChatView through `onBlockStatusChanged`.
    private func toggleBlock() async {
        guard let otherId = peer.otherUserId,
              let blocked = await viewModel.toggleBlock(otherUserId: otherId) else { return }
        onBlockStatusChanged?(blocked)
    }

    /// Subtitle under "Default auto-delete time" describing the current preference.
    private var pinAutoDeleteSubtitle: String {
        let option = PinAutoDeleteOption(rawValue: pinAutoDeleteRaw) ?? .never
        if option == .custom, pinAutoDeleteCustomDateRaw > 0 {
            return Date(timeIntervalSince1970: pinAutoDeleteCustomDateRaw).dayMonthYear
        }
        return bundle.loc(option.label)
    }

    /// Subtitle under "Mute notifications" describing the current state.
    private var muteSubtitle: String? {
        guard let settings = viewModel.settings, settings.isMuted, let until = settings.mutedUntil else { return nil }
        if settings.isMutedIndefinitely {
            return bundle.loc("Muted until you turn it back on")
        }
        return String(format: bundle.loc("Muted until %@"), until.formatted(.dateTime.hour().minute()))
    }

    // MARK: - Theme picker

    private var themePickerSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                    ForEach(ThemePalette.allPalettes) { palette in
                        Button {
                            Task { await viewModel.selectTheme(palette.id) }
                            showThemePicker = false
                        } label: {
                            swatch(palette)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Chat theme"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Default")) {
                        Task { await viewModel.selectTheme(nil) }
                        showThemePicker = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { showThemePicker = false }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func swatch(_ palette: ThemePalette) -> some View {
        let isSelected = viewModel.settings?.theme == palette.id
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(palette.primaryGradient).frame(width: 56, height: 56)
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(20, .bold)
                        .foregroundColor(.white)
                }
            }
            .overlay(
                Circle().stroke(AppColors.textPrimary(colorScheme).opacity(isSelected ? 0.9 : 0), lineWidth: 2)
            )
            Text(palette.name)
                .scaledFont(12)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    // MARK: - Group photo (color swatch) picker
    // No photo-upload flow exists for chat groups yet (only the media-message
    // upload path exists), so "Group photo" exposes the same avatar_color
    // fallback every `ConversationPeer`/`ChatPeer` already renders when a
    // group has no `avatar_url` photo. Mirrors the chat-theme swatch picker above.

    private var groupColorPickerSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 16)], spacing: 16) {
                    ForEach(groupColorSwatches, id: \.self) { hex in
                        Button {
                            Task { await viewModel.updateGroupColor(hex) }
                            showGroupColorPicker = false
                        } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 52, height: 52)
                                .overlay(
                                    Circle().stroke(
                                        AppColors.textPrimary(colorScheme).opacity(
                                            viewModel.settings?.groupAvatarColor == hex ? 0.9 : 0),
                                        lineWidth: 3
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Group photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { showGroupColorPicker = false }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Pin default auto-delete: custom date picker

    private var pinCustomDatePickerSheet: some View {
        NavigationStack {
            Form {
                DatePicker(bundle.loc("Custom date"), selection: $pinCustomDateDraft, in: Date()...,
                           displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle(bundle.loc("Custom date"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) {
                        pinAutoDeleteRaw = PinAutoDeleteOption.custom.rawValue
                        pinAutoDeleteCustomDateRaw = pinCustomDateDraft.timeIntervalSince1970
                        showPinCustomDatePicker = false
                    }
                    .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Pin auto-delete preference (client-side-only convenience default)

/// How long a newly-pinned message should stay pinned before auto-expiring,
/// there is no conversation-level default server-side (`expires_at` is set
/// per-pin at pin time); this only prefills the expiry sheet `ChatView` shows
/// when pinning a message.
enum PinAutoDeleteOption: String, CaseIterable, Identifiable {
    case week, month, year, custom, never
    var id: String { rawValue }

    /// English fallback / localization key.
    var label: String {
        switch self {
        case .week:   return "1 week"
        case .month:  return "1 month"
        case .year:   return "1 year"
        case .custom: return "Custom date"
        case .never:  return "Never"
        }
    }

    /// Resolves this option to a concrete expiry date from `now`. `nil` means
    /// "never expires"; `.custom` uses the caller-supplied date.
    func expiryDate(from now: Date = Date(), customDate: Date? = nil) -> Date? {
        switch self {
        case .week:   return Calendar.current.date(byAdding: .day, value: 7, to: now)
        case .month:  return Calendar.current.date(byAdding: .month, value: 1, to: now)
        case .year:   return Calendar.current.date(byAdding: .year, value: 1, to: now)
        case .custom: return customDate
        case .never:  return nil
        }
    }
}

/// Namespaced `@AppStorage` keys for the per-conversation pin auto-delete
/// default, so each conversation remembers its own preference independently.
func pinAutoDeleteStorageKey(conversationId: String) -> String { "pinAutoDelete.\(conversationId)" }
func pinAutoDeleteCustomDateStorageKey(conversationId: String) -> String { "pinAutoDeleteCustomDate.\(conversationId)" }
/// Per-conversation quick-emoji send. The emoji the send button becomes while
/// the message box is empty. Read by `ChatView` and `FloatingChatComposerBar`.
func quickEmojiStorageKey(conversationId: String) -> String { "quickEmoji.\(conversationId)" }

// MARK: - Reusable settings row

private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let colorScheme: ColorScheme
    var subtitle: String? = nil
    var destructive: Bool = false
    var showsChevron: Bool = false
    var trailing: AnyView? = nil
    /// Drawn instead of the SF Symbol (e.g. the Spaces planet).
    var customIcon: AnyView? = nil

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let customIcon {
                    customIcon
                } else {
                    Image(systemName: icon)
                        .scaledFont(16, .semibold)
                        .foregroundColor(iconColor)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: destructive ? .semibold : .regular))
                    .foregroundColor(destructive ? .red : AppColors.textPrimary(colorScheme))
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(12)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            Spacer()

            if let trailing {
                trailing
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
