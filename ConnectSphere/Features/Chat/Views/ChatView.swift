import SwiftUI
import PhotosUI
import AudioToolbox

struct ChatView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle
    @Environment(FloatingChatPresenter.self) var floatingChatPresenter

    let conversationId: String
    let peer: ChatPeer
    let otherUserLocation: String?
    private let token: String
    /// Set when opened from a cross-conversation search hit — scrolls to and
    /// highlights this message once the initial page has loaded.
    let initialJumpMessageId: String?

    @State private var viewModel: ChatViewModel
    /// True when `viewModel` was handed in already-loaded (restoring from a
    /// floating bubble) — `.task` skips the initial `loadMessages()` fetch
    /// since the message list is already live/current, avoiding both a
    /// wasted request and a re-fetch flash that could momentarily replace
    /// messages received while the bubble was floating.
    private let isRestoredFromBubble: Bool
    /// Set right before calling `dismiss()` from the "shrink to bubble"
    /// button — tells `.onDisappear` to skip `leaveConversation()`, since the
    /// conversation is transferring to a `FloatingChatPresenter` bubble, not
    /// actually closing.
    @State private var isMinimizing = false
    @State private var inputText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var voiceSession = VoiceRecordingSession()
    @State private var pendingMedia: [PendingMedia] = []
    @State private var isTyping = false
    @State private var appearedMessageIDs: Set<String> = []
    @State private var showChatSettings = false
    @State private var mediaViewerItem: ChatMediaViewerItem?
    // Whether either side has blocked the other — disables the input bar and
    // shows an inline notice; set from Chat Settings' block toggle or fetched
    // on load. 1:1 only — groups use `viewModel.blockAlertState` instead
    // (alert-only, input bar stays enabled).
    @State private var isBlocked = false
    /// Token for the `.userBlockStatusChanged` observer registered in `.task`;
    /// removed symmetrically in `.onDisappear`.
    @State private var blockStatusObserver: NSObjectProtocol?
    /// Token for the `.userLeftGroupConversation` observer (group only) —
    /// catches "I left via `GroupParticipantsView`" deterministically on this
    /// same device, independent of the `member_removed` socket broadcast's
    /// exact targeting. Removed symmetrically in `.onDisappear`.
    @State private var leftGroupObserver: NSObjectProtocol?
    // Meeting proposal composer (new proposal or reschedule) — forked
    // `MeetingProposalComposerView`, see its doc comment for why.
    @State private var showMeetingComposer = false
    @State private var meetingTitle = ""
    @State private var meetingLocation = ""
    @State private var meetingStartsAt = Date().addingTimeInterval(3600)
    @State private var meetingEndsAt: Date? = nil
    @State private var meetingShowEndDate = false
    @State private var meetingReminderOffset: MeetingReminderOffset = .oneDayBefore
    /// Non-nil while rescheduling an existing proposal — the id of the message being edited.
    @State private var editingMeetingMessageId: String?
    // Jump-to-message from search results (and from tapping a reply's quoted preview)
    @State private var pendingScrollTarget: String?
    @State private var highlightedMessageId: String?
    @State private var isJumping = false
    // The message currently being quoted for a reply — shows a preview bar above the input bar
    @State private var replyingTo: Message?
    /// Raised when a reply starts (swipe or long-press), so the keyboard comes
    /// up ready to type the way Messenger does.
    @FocusState private var isComposerFocused: Bool
    @State private var messageToRecall: Message?
    // "Forward" — pick a target conversation, re-send this message's content there.
    @State private var forwardingMessage: Message?
    @State private var isForwarding = false
    @State private var connectVM = ConnectViewModel()
    @AppStorage("messageSoundEnabled") private var messageSoundEnabled = true
    private let bottomID = "chatBottom"

    // Pin / unpin: lightweight expiry-confirmation sheet shown from the
    // context menu, prefilled from the per-conversation default (settings'
    // "Default auto-delete time" row) rather than silently applying it.
    @State private var pinningMessage: Message?
    @State private var pinExpiryChoice: PinAutoDeleteOption = .never
    @State private var pinCustomDate = Date()
    @AppStorage private var pinAutoDeleteRaw: String
    @AppStorage private var pinAutoDeleteCustomDateRaw: Double
    /// The emoji the send button becomes while the composer is empty — shared
    /// with the floating chat's composer bar, set in Chat settings.
    @AppStorage private var quickEmoji: String
    // Pinned-messages list, opened from the pinned-banner when there's more
    // than one pin (a single pin jumps straight to it via `jumpToMessage`).
    @State private var showPinnedList = false
    @State private var pinsSettingsViewModel: ChatSettingsViewModel

    init(conversationId: String, peer: ChatPeer, otherUserLocation: String? = nil,
         currentUserId: String, token: String, initialJumpMessageId: String? = nil,
         existingViewModel: ChatViewModel? = nil) {
        self.conversationId = conversationId
        self.peer = peer
        self.otherUserLocation = otherUserLocation
        self.token = token
        self.initialJumpMessageId = initialJumpMessageId
        self.isRestoredFromBubble = existingViewModel != nil
        // Restoring from a floating bubble hands in its already-loaded,
        // already-joined view model — reused as-is (no re-fetch, no second
        // socket join; see `ChatViewModel.hasJoinedConversation`'s guard and
        // `FloatingChatPresenter.restore(_:)`).
        _viewModel = State(initialValue: existingViewModel ?? ChatViewModel(
            conversationId: conversationId,
            currentUserId: currentUserId,
            isGroup: peer.isGroup,
            otherUserId: peer.otherUserId,
            token: token
        ))
        _pinsSettingsViewModel = State(initialValue: ChatSettingsViewModel(conversationId: conversationId, token: token))
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

    /// Palette for this conversation: its shared theme if set, else the global theme.
    private var chatPalette: ThemePalette {
        ThemePalette.byId(viewModel.chatThemeId) ?? themeManager.theme
    }

    /// Name to show in the header: shared nickname (1:1) or group name — live
    /// value from settings once loaded, falling back to what the caller passed in.
    private var headerName: String {
        if viewModel.isGroup {
            return viewModel.groupName ?? peer.name
        }
        return viewModel.otherNickname ?? peer.name
    }

    /// "N members" subtitle under the group's name — nil for 1:1.
    private var groupMemberCountText: String? {
        guard viewModel.isGroup else { return nil }
        let count = viewModel.groupMembers.isEmpty ? (peer.memberCount ?? 0) : viewModel.groupMembers.count
        guard count > 0 else { return nil }
        return String(format: bundle.loc("%d members"), count)
    }

    /// Every other participant in this conversation (current user excluded) —
    /// fed to `MessageBubble.otherParticipantIds` to derive delivered/read
    /// status. A 1:1 chat yields exactly `[peer.otherUserId]`; a group yields
    /// the live roster from `viewModel.groupMembers` (falls back to `[]`
    /// before settings finish loading, which just renders the sent-only glyph
    /// briefly — matches how `groupMemberCountText` already tolerates the
    /// same not-yet-loaded window).
    private var otherParticipantIds: [String] {
        if viewModel.isGroup {
            let me = appState.currentUser?.id ?? ""
            return viewModel.groupMembers.map(\.id).filter { $0 != me }
        }
        return peer.otherUserId.map { [$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.pinnedMessages.isEmpty {
                pinnedBanner
                Divider()
            }
            messageList
            Divider()
            inputBar
        }
        // ignoresSafeArea (which covers .keyboard by default) so the background extends behind
        // iOS 26's floating keyboard — otherwise there's a system black bar between the input bar and the keyboard
        .background(AppColors.base(colorScheme).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Back button
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
            }

            // Tappable display name (+ member count for groups) → chat settings
            ToolbarItem(placement: .principal) {
                Button { showChatSettings = true } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            Text(headerName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            if viewModel.isMuted {
                                Image(systemName: "bell.slash.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                            }
                        }
                        if let subtitle = groupMemberCountText {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Avatar → chat settings
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showChatSettings = true } label: {
                    headerAvatar
                }
                .buttonStyle(.plain)
            }

            // Shrink to a floating "chat head" — keeps this conversation
            // live (still receiving/sendable) while browsing any other tab.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isMinimizing = true
                    floatingChatPresenter.minimize(
                        conversationId: conversationId, peer: peer,
                        otherUserLocation: otherUserLocation,
                        currentUserId: appState.currentUser?.id ?? "", token: token,
                        viewModel: viewModel
                    )
                    dismiss()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
            }
        }
        .sheet(isPresented: $showChatSettings) {
            ChatSettingsView(
                conversationId: conversationId,
                peer: peer,
                token: token,
                onCleared: {
                    viewModel.messages = []
                    viewModel.hasMoreMessages = false
                    appearedMessageIDs = []
                },
                onJumpToMessage: { messageId in
                    Task { await jumpToMessage(messageId) }
                },
                onBlockStatusChanged: { blocked in
                    isBlocked = blocked
                }
            )
            .environment(appState)
        }
        .task {
            // Must run before `joinConversation()` — see `fullChatDidAppear`.
            floatingChatPresenter.fullChatDidAppear(conversationId: conversationId)
            viewModel.joinConversation()
            if !isRestoredFromBubble {
                await viewModel.loadMessages()
            }
            // Existing history should appear without the send animation.
            appearedMessageIDs = Set(viewModel.messages.map(\.id))
            if let initialJumpMessageId {
                await jumpToMessage(initialJumpMessageId)
            }
            viewModel.markRead()
            await viewModel.markConversationDelivered()
            await viewModel.loadSettings()
            await viewModel.loadPins()
            if viewModel.isGroup {
                // Groups are alert-only (Leave/Stay) — never disable the input bar.
                await viewModel.checkBlockAlert()
                leftGroupObserver = NotificationCenter.default.addObserver(
                    forName: .userLeftGroupConversation, object: nil, queue: .main
                ) { note in
                    guard let convId = note.userInfo?["conversationId"] as? String,
                          convId == conversationId else { return }
                    viewModel.wasRemovedFromGroup = true
                }
            } else if let otherId = peer.otherUserId {
                // A user may already be blocked via their profile before ever opening
                // Chat Settings — fetch the current state so the input bar reflects it.
                // Uses the bidirectional value: the input bar must stay disabled even
                // when *they* blocked *me*, not just when I blocked them.
                await refreshBlockedState()
                if let me = appState.currentUser?.id {
                    await connectVM.load(
                        viewerId: me,
                        targetId: otherId,
                        mode: appState.currentMode.rawValue
                    )
                }
                // Live cross-screen sync: a block/unblock from UserProfileView (or this
                // conversation's own Chat Settings) for this same person refreshes the
                // input bar without needing to reopen the chat.
                blockStatusObserver = NotificationCenter.default.addObserver(
                    forName: .userBlockStatusChanged, object: nil, queue: .main
                ) { note in
                    guard let changedUserId = note.userInfo?["userId"] as? String,
                          changedUserId == otherId else { return }
                    Task { await refreshBlockedState() }
                }
            }
        }
        .onDisappear {
            // Shrinking to a bubble transfers ownership of the live socket
            // listeners to FloatingChatPresenter instead of tearing them
            // down — see `isMinimizing`'s doc comment.
            if !isMinimizing {
                viewModel.leaveConversation()
            }
            floatingChatPresenter.fullChatDidDisappear()
            // Leaving mid-recording must not leave the mic running in the background.
            voiceSession.cancel()
            if let blockStatusObserver {
                NotificationCenter.default.removeObserver(blockStatusObserver)
                self.blockStatusObserver = nil
            }
            if let leftGroupObserver {
                NotificationCenter.default.removeObserver(leftGroupObserver)
                self.leftGroupObserver = nil
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePickedMedia(items) }
        }
        .onChange(of: showChatSettings) { _, isShowing in
            // Refresh mute/theme/nickname/group info after closing the settings sheet.
            if !isShowing { Task { await viewModel.loadSettings() } }
        }
        .fullScreenCover(item: $mediaViewerItem) { item in
            ChatMediaViewerView(items: [item])
        }
        .sheet(isPresented: $showMeetingComposer) {
            meetingComposerSheet
        }
        .sheet(item: $pinningMessage) { message in
            pinExpirySheet(for: message)
        }
        .sheet(item: $forwardingMessage) { message in
            ForwardMessagePickerView(excludeConversationId: conversationId) { targetConversationId in
                Task { await forward(message, to: targetConversationId) }
            }
            .environment(appState)
            .environment(themeManager)
        }
        .sheet(isPresented: $showPinnedList) {
            NavigationStack {
                ChatPinnedMessagesView(viewModel: pinsSettingsViewModel, onSelect: { pin in
                    showPinnedList = false
                    Task { await jumpToMessage(pin.id) }
                })
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(bundle.loc("Done")) { showPinnedList = false }
                    }
                }
            }
        }
        // Surfaces both socket-ack rejections (send/react/reply/meeting actions)
        // and REST-fallback failures — previously `viewModel.error` was set but
        // never read anywhere, so every one of those failures was silent.
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.error != nil)) {
            Button(bundle.loc("OK")) { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .confirmationDialog(bundle.loc("Unsend this message?"),
                            isPresented: Binding(get: { messageToRecall != nil },
                                                 set: { if !$0 { messageToRecall = nil } }),
                            titleVisibility: .visible,
                            presenting: messageToRecall) { message in
            Button(bundle.loc("Unsend message"), role: .destructive) {
                Task { await viewModel.recallMessage(message) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(bundle.loc("This removes it for everyone in the conversation."))
        }
        // Group-only: someone I've blocked (or who's blocked me) is in this
        // group. Alert-only per product decision — the input bar stays fully
        // enabled either way; only Leave actually removes me from the group.
        .alert(bundle.loc("Blocked members in this group"), isPresented: Binding(
            get: { viewModel.blockAlertState != nil },
            set: { if !$0 { viewModel.blockAlertState = nil } }
        )) {
            Button(bundle.loc("Leave the group"), role: .destructive) {
                Task { await viewModel.leaveGroup() }
            }
            Button(bundle.loc("Stay")) {
                Task { await viewModel.acknowledgeBlockAlert() }
            }
        } message: {
            Text("Someone you've blocked (or who has blocked you) is in this group.", bundle: bundle)
        }
        // I left (or was removed from) this group — it's no longer accessible.
        .alert(bundle.loc("You're no longer in this group"), isPresented: Binding(
            get: { viewModel.wasRemovedFromGroup },
            set: { _ in }
        )) {
            Button(bundle.loc("OK")) { dismiss() }
        }
    }

    // MARK: - Header avatar

    @ViewBuilder
    private var headerAvatar: some View {
        if viewModel.isGroup {
            groupHeaderAvatar
        } else {
            ZStack {
                Circle()
                    .fill(Color(hex: peer.avatarColor))
                    .frame(width: 34, height: 34)
                if let urlString = peer.avatarUrl,
                   let url = URL(string: urlString.hasPrefix("http") ? urlString : APIConfig.serverBase + urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Text(String(headerName.prefix(1)))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                } else {
                    Text(String(headerName.prefix(1)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        }
    }

    /// Group photo if set, else a small overlapping avatar stack from the
    /// first two members, else a plain group-icon placeholder before the
    /// member roster has loaded.
    private var groupHeaderAvatar: some View {
        let urlString = viewModel.groupAvatarUrl ?? peer.avatarUrl
        return Group {
            if let urlString, let url = URL(string: APIConfig.serverBase + urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        groupAvatarStack
                    }
                }
            } else {
                groupAvatarStack
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private var groupAvatarStack: some View {
        let members = Array(viewModel.groupMembers.prefix(2))
        return ZStack {
            if members.isEmpty {
                Circle().fill(Color(hex: viewModel.groupAvatarColor ?? peer.avatarColor))
                Image(systemName: "person.3.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    ZStack {
                        Circle().fill(Color(hex: member.avatarColor))
                        Text(String(member.displayName.prefix(1)))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 1.5))
                    .offset(x: CGFloat(index) * 9 - 4, y: CGFloat(index) * 5 - 2)
                }
            }
        }
    }

    // MARK: - Meeting proposal composer

    /// Hosts `MeetingProposalComposerView`'s fields for both "new proposal"
    /// and "reschedule" — `editingMeetingMessageId` tracks which mode is active.
    private var meetingComposerSheet: some View {
        NavigationStack {
            ScrollView {
                MeetingProposalComposerView(
                    title: $meetingTitle,
                    location: $meetingLocation,
                    startsAt: $meetingStartsAt,
                    endsAt: $meetingEndsAt,
                    showEndDate: $meetingShowEndDate,
                    reminderOffset: $meetingReminderOffset
                )
            }
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showMeetingComposer = false
                        resetMeetingComposer()
                    } label: {
                        Text("Cancel", bundle: bundle)
                    }
                }
                ToolbarItem(placement: .principal) {
                    if editingMeetingMessageId == nil {
                        Text("New meeting", bundle: bundle)
                            .font(.system(size: 17, weight: .semibold))
                    } else {
                        Text("Reschedule meeting", bundle: bundle)
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submitMeetingComposer()
                    } label: {
                        if editingMeetingMessageId == nil {
                            Text("Propose", bundle: bundle)
                        } else {
                            Text("Save", bundle: bundle)
                        }
                    }
                    .disabled(meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Resets the composer's fields back to defaults (new-proposal mode).
    private func resetMeetingComposer() {
        meetingTitle = ""
        meetingLocation = ""
        meetingStartsAt = Date().addingTimeInterval(3600)
        meetingEndsAt = nil
        meetingShowEndDate = false
        meetingReminderOffset = .oneDayBefore
        editingMeetingMessageId = nil
    }

    /// Pre-fills the composer from an existing proposal and opens it in reschedule mode.
    private func openMeetingEditor(for message: Message) {
        guard let proposal = message.meetingProposal else { return }
        editingMeetingMessageId = message.id
        meetingTitle = proposal.title
        meetingLocation = proposal.location ?? ""
        meetingStartsAt = proposal.startsAt
        if let endsAt = proposal.endsAt {
            meetingEndsAt = endsAt
            meetingShowEndDate = true
        } else {
            meetingEndsAt = nil
            meetingShowEndDate = false
        }
        meetingReminderOffset = proposal.reminderOffsetValue ?? .oneDayBefore
        showMeetingComposer = true
    }

    /// Sends a new proposal, or applies a reschedule when `editingMeetingMessageId` is set.
    private func submitMeetingComposer() {
        let title = meetingTitle
        let location = meetingLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsAt = meetingStartsAt
        let endsAt = meetingShowEndDate ? meetingEndsAt : nil
        let reminderOffset = meetingReminderOffset
        let reminderAt = reminderOffset.reminderDate(before: startsAt)
        let editingId = editingMeetingMessageId
        showMeetingComposer = false
        resetMeetingComposer()
        Task {
            if let editingId {
                await viewModel.rescheduleMeeting(
                    messageId: editingId,
                    title: title,
                    location: location.isEmpty ? nil : location,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    reminderOffset: reminderOffset.rawValue,
                    reminderAt: reminderAt
                )
            } else {
                await viewModel.sendMeetingProposal(
                    title: title,
                    location: location.isEmpty ? nil : location,
                    startsAt: startsAt,
                    endsAt: endsAt,
                    reminderOffset: reminderOffset.rawValue,
                    reminderAt: reminderAt
                )
            }
        }
    }

    // MARK: - Pinned messages

    /// Small banner shown above the thread whenever pins exist. With exactly
    /// one pin it shows that pin's preview and tapping jumps straight to it
    /// (same mechanism message search already uses); with more it shows a
    /// count and opens the full pinned list in a sheet.
    private var pinnedBanner: some View {
        Button {
            if viewModel.pinnedMessages.count == 1, let only = viewModel.pinnedMessages.first {
                Task { await jumpToMessage(only.id) }
            } else {
                showPinnedList = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(chatPalette.primary)
                if viewModel.pinnedMessages.count == 1, let only = viewModel.pinnedMessages.first {
                    Text(only.preview)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                } else {
                    Text(String(format: bundle.loc("%d pinned messages"), viewModel.pinnedMessages.count))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppColors.elevated(colorScheme))
        }
        .buttonStyle(.plain)
    }

    /// Opens the pin-expiry confirmation sheet for `message`, prefilled from
    /// the per-conversation default auto-delete preference — always shown
    /// rather than silently applying a hidden default, so the user can see/
    /// adjust the expiry before confirming.
    /// Re-sends `message`'s content/media to a different conversation. No
    /// re-upload needed — the server never ties `media_url` to the sender or
    /// conversation it was originally uploaded in (`MessagesController.sendMessage`),
    /// so the existing URL is reused as-is. Not threaded as a reply in the
    /// target conversation (`replyToMessageId: nil`) since the original
    /// message doesn't exist there.
    private func forward(_ message: Message, to targetConversationId: String) async {
        guard !isForwarding else { return }
        isForwarding = true
        defer { isForwarding = false }
        _ = try? await MessageRepository().sendMessage(
            conversationId: targetConversationId,
            content: message.content,
            messageType: message.messageType,
            mediaUrl: message.mediaUrl,
            replyToMessageId: nil,
            voiceDurationSeconds: message.voiceDurationSeconds,
            voiceWaveform: message.voiceWaveform,
            token: appState.authToken ?? ""
        )
    }

    private func beginPinning(_ message: Message) {
        pinExpiryChoice = PinAutoDeleteOption(rawValue: pinAutoDeleteRaw) ?? .never
        pinCustomDate = pinAutoDeleteCustomDateRaw > 0
            ? Date(timeIntervalSince1970: pinAutoDeleteCustomDateRaw)
            : Date().addingTimeInterval(60 * 60 * 24 * 7)
        pinningMessage = message
    }

    /// Lightweight confirmation sheet for pinning `message`: pick an
    /// auto-delete option (prefilled from the conversation's default), with a
    /// date picker when "Custom date" is selected.
    private func pinExpirySheet(for message: Message) -> some View {
        NavigationStack {
            Form {
                Section {
                    Picker(bundle.loc("Default auto-delete time"), selection: $pinExpiryChoice) {
                        ForEach(PinAutoDeleteOption.allCases) { option in
                            Text(bundle.loc(option.label)).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if pinExpiryChoice == .custom {
                    Section {
                        DatePicker(bundle.loc("Custom date"), selection: $pinCustomDate, in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            .navigationTitle(bundle.loc("Pin message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { pinningMessage = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Pin")) {
                        let expiresAt = pinExpiryChoice.expiryDate(customDate: pinCustomDate)
                        pinningMessage = nil
                        Task { await viewModel.pinMessage(message.id, expiresAt: expiresAt) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.hasMoreMessages {
                        Button {
                            Task {
                                await viewModel.loadOlderMessages()
                                // Older history is not "new", so skip its animation too.
                                appearedMessageIDs.formUnion(viewModel.messages.map(\.id))
                            }
                        } label: {
                            Text("Load older messages", bundle: bundle)
                                .font(.system(size: 13))
                                .foregroundColor(chatPalette.primary)
                                .padding(.vertical, 10)
                        }
                    }

                    if viewModel.isLoading && viewModel.messages.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        // One view per row (separator + bubble) so `scrollTo` and the
                        // appear animation keep targeting a single thing per message id.
                        let messages = viewModel.messages
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let isOwn = message.isOwn(userId: appState.currentUser?.id ?? "")
                            VStack(spacing: 0) {
                                if ChatTimeline.showsSeparator(before: index, in: messages) {
                                    timeSeparator(for: message.createdAt)
                                }
                                MessageBubble(message: message, isOwn: isOwn, palette: chatPalette,
                                              currentUserId: appState.currentUser?.id ?? "",
                                              otherParticipantIds: otherParticipantIds,
                                              isGroup: viewModel.isGroup,
                                              isPlayful: appState.currentMode == .hobby,
                                              showsMeta: ChatTimeline.endsRun(at: index, in: messages),
                                              onMediaTap: openMediaViewer,
                                              onReplyPreviewTap: { messageId in
                                                  Task { await jumpToMessage(messageId) }
                                              },
                                              onMeetingRespond: { msg, status in
                                                  Task { await viewModel.respondToMeeting(messageId: msg.id, status: status) }
                                              },
                                              onMeetingEdit: { msg in
                                                  openMeetingEditor(for: msg)
                                              },
                                              onMeetingCancel: { msg in
                                                  Task { await viewModel.cancelMeeting(messageId: msg.id) }
                                              })
                                    .modifier(MessageAppearModifier(
                                        id: message.id,
                                        appearedIDs: $appearedMessageIDs,
                                        playful: appState.currentMode == .hobby,
                                        onAnimationFinished: { playMessageSound(isOwn: isOwn) }
                                    ))
                                    // Flash the background when jumped to from a search result
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(chatPalette.primary.opacity(
                                                message.id == highlightedMessageId ? 0.16 : 0))
                                            .padding(.horizontal, 6)
                                    )
                                    .modifier(SwipeToReplyModifier(
                                        direction: isOwn ? -1 : 1,
                                        isEnabled: !message.isDeleted && !(isBlocked && !viewModel.isGroup),
                                        onReply: { beginReply(to: message) }
                                    ))
                                    .contextMenu {
                                        // The quick-react row must be a true top-level, unconditional
                                        // first item — a ControlGroup wrapped inside an `if` (as this
                                        // was previously) can lose iOS's "first ControlGroup renders as
                                        // its own horizontal strip, separate from the vertical action
                                        // list below" behavior, since the menu content is then a
                                        // conditional-content node rather than a plain ControlGroup.
                                        // Reactions become an empty (so effectively invisible) group
                                        // for a deleted message instead of wrapping the whole thing.
                                        ControlGroup {
                                            let myReaction = message.myReaction(userId: appState.currentUser?.id ?? "")
                                            // Hobby keeps the full set (already the max the server
                                            // allows); Work is curated to the two most professional-
                                            // reading emoji in that same allowlist (server:
                                            // ChatStore.reactionEmoji). Deleted messages get none.
                                            let quickReactions: [ReactionEmoji] = message.isDeleted ? [] :
                                                (appState.currentMode == .hobby ? ReactionEmoji.allCases : [.thumbsUp, .heart])
                                            ForEach(quickReactions, id: \.rawValue) { r in
                                                // Distinguish the current user's own reaction (if any)
                                                // in the quick-react row, mirroring MessageBubble's
                                                // highlighted pill for the same reaction.
                                                Button(r.rawValue == myReaction ? "\(r.rawValue) ✓" : r.rawValue) {
                                                    Task { await viewModel.sendReaction(messageId: message.id, emoji: r.rawValue) }
                                                }
                                            }
                                        }

                                        if !message.isDeleted {
                                            Button {
                                                beginReply(to: message)
                                            } label: {
                                                Label(bundle.loc("Reply"), systemImage: "arrowshape.turn.up.left")
                                            }

                                            // Meeting proposals carry RSVP/reminder state tied to this
                                            // specific conversation — forwarding one as-is wouldn't
                                            // make sense, so it's excluded here.
                                            if message.messageType != .meeting {
                                                Button {
                                                    forwardingMessage = message
                                                } label: {
                                                    Label(bundle.loc("Forward"), systemImage: "arrowshape.turn.up.right")
                                                }
                                            }

                                            if viewModel.pinnedMessageIds.contains(message.id) {
                                                Button {
                                                    Task { await viewModel.unpinMessage(message.id) }
                                                } label: {
                                                    Label(bundle.loc("Unpin"), systemImage: "pin.slash")
                                                }
                                            } else {
                                                Button {
                                                    beginPinning(message)
                                                } label: {
                                                    Label(bundle.loc("Pin"), systemImage: "pin")
                                                }
                                            }
                                        }
                                        if isOwn && !message.isDeleted {
                                            Button(role: .destructive) {
                                                messageToRecall = message
                                            } label: {
                                                Label(bundle.loc("Unsend message"), systemImage: "arrow.uturn.backward")
                                            }
                                        }
                                    }
                            }
                        }
                    }

                    if let summary = viewModel.typingSummary {
                        VStack(alignment: .leading, spacing: 2) {
                            if viewModel.isGroup {
                                Text(summary)
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                                    .padding(.leading, 16)
                            }
                            TypingIndicatorBubble()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    }

                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // While jumping, don't auto-scroll to bottom for the older pages that just loaded
                guard !isJumping else { return }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.typingSummary) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                highlightedMessageId = target
                pendingScrollTarget = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isJumping = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        if highlightedMessageId == target { highlightedMessageId = nil }
                    }
                }
            }
            .task { scrollToBottom(proxy: proxy, animated: false) }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isGroup {
            groupEmptyState
        } else {
            directEmptyState
        }
    }

    @ViewBuilder
    private var directEmptyState: some View {
        let isConnected = connectVM.status == .accepted

        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            // Large avatar
            ZStack {
                Circle()
                    .fill(Color(hex: peer.avatarColor))
                    .frame(width: 80, height: 80)
                Text(String(peer.name.prefix(1)))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }

            // Display name
            Text(peer.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            // Connection status
            Text(isConnected
                 ? bundle.loc(appState.currentMode == .hobby
                              ? "You're connected — say hello 👋"
                              : "You're connected. Say hello.")
                 : bundle.loc("You're not connected with this user"))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Location
            if let location = otherUserLocation, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 13))
                    Text(location)
                        .font(.system(size: 13))
                }
                .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    private var groupEmptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            groupAvatarStack
                .frame(width: 80, height: 80)
                .scaleEffect(1.4)

            Text(headerName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.top, 10)

            Text(appState.currentMode == .hobby
                 ? bundle.loc("Say hello to the group 👋")
                 : bundle.loc("Say hello to the group."))
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    /// Starts replying to `message` — shared by swipe-to-reply and the
    /// long-press "Reply" item so both show the "Replying to" bar and raise
    /// the keyboard identically.
    private func beginReply(to message: Message) {
        replyingTo = message
        isComposerFocused = true
    }

    /// Centered time label between messages after 30+ minutes of silence (or a
    /// new day) — Messenger's convention. With it, each bubble no longer needs
    /// its own timestamp; see `ChatTimeline`.
    private func timeSeparator(for date: Date) -> some View {
        Text(ChatTimeline.separatorLabel(for: date, yesterday: bundle.loc("Yesterday")))
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppColors.textTertiary(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        // Groups are alert-only (Leave/Stay) — the input bar always stays
        // enabled there. The existing hard-block disabling/notice is 1:1 only.
        let blocking = isBlocked && !viewModel.isGroup
        return VStack(spacing: 8) {
            if blocking {
                blockedNotice
            }

            // "Replying to X" preview — clearable with an X button
            if let replyingTo {
                replyingToBar(replyingTo)
            }

            // Preview of the selected media before sending
            if !pendingMedia.isEmpty {
                mediaPreview
            }

            HStack(alignment: .bottom, spacing: 10) {
                if voiceSession.state == .idle {
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 10,
                                 matching: .any(of: [.images, .videos])) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundColor(chatPalette.primary)
                            .padding(.bottom, 6)
                    }

                    Button {
                        resetMeetingComposer()
                        showMeetingComposer = true
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 22))
                            .foregroundColor(chatPalette.primary)
                            .padding(.bottom, 6)
                    }

                    VoiceRecorderControl(session: voiceSession, tint: chatPalette.primary)

                    TextField("", text: $inputText, prompt: Text("Message...", bundle: bundle), axis: .vertical)
                        .focused($isComposerFocused)
                        .font(.system(size: 15))
                        .lineLimit(1...5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppColors.borderStrong(colorScheme), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                        .onChange(of: inputText) { _, newVal in
                            let typing = !newVal.isEmpty
                            if typing != isTyping {
                                isTyping = typing
                                viewModel.sendTyping(typing)
                            }
                        }
                } else {
                    // Recording or reviewing — the voice pill takes the whole
                    // row up to the send button, which sends the recording.
                    VoiceComposerBar(session: voiceSession, tint: chatPalette.primary)
                }

                Button {
                    if voiceSession.state != .idle {
                        let replyToId = replyingTo?.id
                        replyingTo = nil
                        voiceSession.finalizeAndSend { fileURL, duration, waveform in
                            Task {
                                await viewModel.sendMedia(
                                    fileURL: fileURL,
                                    replyTo: replyToId,
                                    voiceDurationSeconds: duration,
                                    voiceWaveform: waveform
                                )
                                try? FileManager.default.removeItem(at: fileURL)
                            }
                        }
                    } else if canSend {
                        sendPending()
                    } else {
                        sendQuickEmoji()
                    }
                } label: {
                    Group {
                        if canSend || voiceSession.state != .idle {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(chatPalette.primary)
                        } else {
                            // Never grey for an empty field: a grey control
                            // reads as "this can't be used", so instead send
                            // becomes a one-tap quick-emoji send.
                            Text(quickEmoji)
                                .font(.system(size: 27))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .padding(.bottom, 2)
                }
                .disabled(viewModel.isSending || blocking)
            }
            .disabled(blocking)
            .opacity(blocking ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface(colorScheme))
        // A light tap as recording starts and stops, so it registers without looking.
        .sensoryFeedback(.impact(weight: .light), trigger: voiceSession.state)
    }

    /// Short notice shown above the composer while either side has blocked the other. 1:1 only.
    private var blockedNotice: some View {
        Text("You've blocked this user", bundle: bundle)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// "Replying to X" bar shown above the composer while `replyingTo` is set.
    private func replyingToBar(_ message: Message) -> some View {
        let preview: String = {
            switch message.messageType {
            case .text, .unknown: return message.content ?? ""
            case .image:   return bundle.loc("Photo")
            case .video:   return bundle.loc("Video")
            case .meeting: return bundle.loc("Meeting")
            case .voice:   return bundle.loc("Voice message")
            }
        }()

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(chatPalette.primary)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: bundle.loc("Replying to %@"), senderDisplayName(for: message)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(chatPalette.primary)
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Resolves who to show in "Replying to X": for a group, the actual
    /// sender of `message` (any member, not just "the other person") —
    /// looked up via the loaded roster since `Message` only carries a
    /// `senderId`, not a name. For 1:1, the only two possible senders are me
    /// or the other person, so `peer.name` (or its live nickname) still applies.
    private func senderDisplayName(for message: Message) -> String {
        if message.isOwn(userId: appState.currentUser?.id ?? "") { return bundle.loc("You") }
        if viewModel.isGroup {
            return viewModel.groupMembers.first(where: { $0.id == message.senderId })?.displayName
                ?? bundle.loc("Someone")
        }
        return headerName
    }

    /// Whether the send button should be active (text and/or media present).
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingMedia.isEmpty
    }

    /// Horizontal strip of thumbnails for the picked media, each with a remove button.
    private var mediaPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(pendingMedia) { media in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = media.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                // Video (or non-image) placeholder
                                ZStack {
                                    Rectangle().fill(AppColors.elevated(colorScheme))
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button {
                            pendingMedia.removeAll { $0.id == media.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .offset(x: 6, y: -6)
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Sends every pending media item (if any) and the text, then clears the composer.
    /// The reply reference (if any) is attached only to the first item sent, then cleared.
    private func sendPending() {
        let text = inputText
        let media = pendingMedia
        let replyToId = replyingTo?.id
        inputText = ""
        pendingMedia = []
        replyingTo = nil
        isTyping = false
        viewModel.sendTyping(false)
        Task {
            var replyTo = replyToId
            for item in media {
                await viewModel.sendMedia(fileURL: item.url, replyTo: replyTo)
                replyTo = nil
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await viewModel.sendText(text, replyTo: replyTo)
            }
        }
    }

    /// Sends the configured quick emoji as an ordinary text message — there is
    /// no sticker message type (`MessageType` is text/image/video/meeting/voice),
    /// so Messenger-style one-tap send is simply a very short text.
    private func sendQuickEmoji() {
        Task { await viewModel.sendText(quickEmoji) }
    }

    // MARK: - Helpers

    /// Re-fetches the bidirectional block state with the other 1:1 participant
    /// and applies it to `isBlocked` — used on load and whenever
    /// `.userBlockStatusChanged` fires for this person, so the input bar
    /// reflects either direction of a block. 1:1 only.
    private func refreshBlockedState() async {
        guard let otherId = peer.otherUserId else { return }
        let status = try? await UserRepository().fetchBlockStatusDetailed(userId: otherId)
        isBlocked = status?.blockedEitherWay ?? isBlocked
    }

    /// Jump to a message from search results: load older history until the
    /// message is found (up to 10 pages), scroll it to the middle of the screen and flash-highlight it.
    private func jumpToMessage(_ messageId: String) async {
        isJumping = true
        // Wait for the settings sheet to finish closing so the scroll doesn't get swallowed by its animation
        try? await Task.sleep(for: .milliseconds(300))
        let found = await viewModel.loadUntilFound(messageId: messageId)
        // The older pages that just loaded should appear immediately, without the "new message" animation
        appearedMessageIDs.formUnion(viewModel.messages.map(\.id))
        guard found else {
            isJumping = false
            return
        }
        pendingScrollTarget = messageId
    }

    /// Open the fullscreen viewer for a bubble's image/video.
    private func openMediaViewer(_ message: Message) {
        guard let url = message.absoluteMediaURL() else { return }
        mediaViewerItem = ChatMediaViewerItem(
            id: message.id,
            url: url,
            isVideo: message.messageType == .video
        )
    }

    /// Plays a short system sound once a message finishes its appear animation.
    /// Incoming tone is skipped while the conversation is muted; the own-send
    /// whoosh stays because it is feedback for the user's own action.
    private func playMessageSound(isOwn: Bool) {
        guard messageSoundEnabled else { return }
        if !isOwn && viewModel.isMuted { return }
        // 1004 = "message sent" whoosh, 1003 = "message received" tone.
        AudioServicesPlaySystemSound(isOwn ? 1004 : 1003)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func handlePickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let media = try? await item.loadTransferable(type: MediaFileTransferable.self) else { continue }
            // Build a thumbnail for images; videos fall back to a placeholder in the preview.
            let image = UIImage(contentsOfFile: media.url.path).map { Image(uiImage: $0) }
            pendingMedia.append(PendingMedia(url: media.url, image: image))
        }
        pickerItems = []
    }
}

// `PendingMedia` and `MediaFileTransferable` now live in
// `ChatMediaTransferable.swift`, shared with the floating chat's docked composer.

// MARK: - Message appear animation

/// Scales a message bubble up while sliding it in from the bottom the first time it
/// appears, then fires a completion callback (used to play a sound). Messages already
/// present in `appearedIDs` (loaded history) are shown instantly with no animation.
private struct MessageAppearModifier: ViewModifier {
    let id: String
    @Binding var appearedIDs: Set<String>
    /// Hobby mode gets a bouncier spring (lower damping, bigger start offset);
    /// Work mode a calmer one. Duration is shared so `onAnimationFinished`'s
    /// sound-cue timing stays the same regardless of mode.
    let playful: Bool
    let onAnimationFinished: () -> Void

    @State private var shown = false

    private let duration = 0.35
    private var startScale: CGFloat { playful ? 0.55 : 0.9 }
    private var startYOffset: CGFloat { playful ? 24 : 10 }
    private var dampingFraction: CGFloat { playful ? 0.6 : 0.85 }

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : startScale, anchor: .bottom)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : startYOffset)
            .onAppear {
                if appearedIDs.contains(id) {
                    shown = true
                    return
                }
                appearedIDs.insert(id)
                withAnimation(.spring(response: duration, dampingFraction: dampingFraction)) {
                    shown = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    onAnimationFinished()
                }
            }
    }
}
