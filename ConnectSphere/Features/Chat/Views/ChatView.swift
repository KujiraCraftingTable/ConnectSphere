import SwiftUI
import PhotosUI
import AudioToolbox

struct ChatView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle

    let conversationId: String
    let otherUserId: String
    let otherUserName: String
    let otherUserAvatarColor: String
    let otherUserLocation: String?
    private let token: String

    @State private var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pendingMedia: [PendingMedia] = []
    @State private var isTyping = false
    @State private var appearedMessageIDs: Set<String> = []
    @State private var showChatSettings = false
    @State private var mediaViewerItem: ChatMediaViewerItem?
    // Meeting proposal composer (new proposal or reschedule, reusing CreateEventSheet)
    @State private var showMeetingComposer = false
    @State private var meetingTitle = ""
    @State private var meetingLocation = ""
    @State private var meetingStartsAt = Date().addingTimeInterval(3600)
    @State private var meetingEndsAt: Date? = nil
    @State private var meetingShowEndDate = false
    /// Non-nil while rescheduling an existing proposal — the id of the message being edited.
    @State private var editingMeetingMessageId: String?
    // Jump-to-message từ kết quả tìm kiếm (và từ tap vào quoted preview của reply)
    @State private var pendingScrollTarget: String?
    @State private var highlightedMessageId: String?
    @State private var isJumping = false
    // Tin đang được trích dẫn để trả lời (Reply) — hiện thanh preview trên input bar
    @State private var replyingTo: Message?
    @State private var connectVM = ConnectViewModel()
    @AppStorage("messageSoundEnabled") private var messageSoundEnabled = true
    private let bottomID = "chatBottom"

    init(conversationId: String, otherUserId: String, otherUserName: String,
         otherUserAvatarColor: String, otherUserLocation: String? = nil,
         currentUserId: String, token: String) {
        self.conversationId = conversationId
        self.otherUserId = otherUserId
        self.otherUserName = otherUserName
        self.otherUserAvatarColor = otherUserAvatarColor
        self.otherUserLocation = otherUserLocation
        self.token = token
        _viewModel = State(initialValue: ChatViewModel(
            conversationId: conversationId,
            currentUserId: currentUserId,
            otherUserId: otherUserId,
            token: token
        ))
    }

    /// Palette for this conversation: its shared theme if set, else the global theme.
    private var chatPalette: ThemePalette {
        ThemePalette.byId(viewModel.chatThemeId) ?? themeManager.theme
    }

    /// Name to show for the other person (shared nickname overrides real name).
    private var headerName: String {
        viewModel.otherNickname ?? otherUserName
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        // ignoresSafeArea (mặc định gồm cả .keyboard) để nền phủ ra sau bàn phím
        // nổi của iOS 26 — không còn dải đen hệ thống giữa input bar và bàn phím
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

            // Tappable display name → chat settings
            ToolbarItem(placement: .principal) {
                Button { showChatSettings = true } label: {
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
                }
                .buttonStyle(.plain)
            }

            // Avatar → chat settings
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showChatSettings = true } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: otherUserAvatarColor))
                            .frame(width: 34, height: 34)
                        Text(String(headerName.prefix(1)))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showChatSettings) {
            ChatSettingsView(
                conversationId: conversationId,
                otherUserId: otherUserId,
                fallbackName: otherUserName,
                avatarColor: otherUserAvatarColor,
                token: token,
                onCleared: {
                    viewModel.messages = []
                    viewModel.hasMoreMessages = false
                    appearedMessageIDs = []
                },
                onJumpToMessage: { messageId in
                    Task { await jumpToMessage(messageId) }
                }
            )
            .environment(appState)
        }
        .task {
            viewModel.joinConversation()
            await viewModel.loadMessages()
            // Existing history should appear without the send animation.
            appearedMessageIDs = Set(viewModel.messages.map(\.id))
            viewModel.markRead()
            await viewModel.loadSettings()
            if let me = appState.currentUser?.id {
                await connectVM.load(
                    viewerId: me,
                    targetId: otherUserId,
                    mode: appState.currentMode.rawValue
                )
            }
        }
        .onDisappear {
            viewModel.leaveConversation()
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePickedMedia(items) }
        }
        .onChange(of: showChatSettings) { _, isShowing in
            // Refresh mute/theme/nickname after closing the settings sheet.
            if !isShowing { Task { await viewModel.loadSettings() } }
        }
        .fullScreenCover(item: $mediaViewerItem) { item in
            ChatMediaViewerView(items: [item])
        }
        .sheet(isPresented: $showMeetingComposer) {
            meetingComposerSheet
        }
    }

    // MARK: - Meeting proposal composer

    /// Hosts the reused `CreateEventSheet` fields for both "new proposal" and
    /// "reschedule" — `editingMeetingMessageId` tracks which mode is active.
    private var meetingComposerSheet: some View {
        NavigationStack {
            ScrollView {
                CreateEventSheet(
                    title: $meetingTitle,
                    location: $meetingLocation,
                    startsAt: $meetingStartsAt,
                    endsAt: $meetingEndsAt,
                    showEndDate: $meetingShowEndDate
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
        showMeetingComposer = true
    }

    /// Sends a new proposal, or applies a reschedule when `editingMeetingMessageId` is set.
    private func submitMeetingComposer() {
        let title = meetingTitle
        let location = meetingLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsAt = meetingStartsAt
        let endsAt = meetingShowEndDate ? meetingEndsAt : nil
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
                    endsAt: endsAt
                )
            } else {
                await viewModel.sendMeetingProposal(
                    title: title,
                    location: location.isEmpty ? nil : location,
                    startsAt: startsAt,
                    endsAt: endsAt
                )
            }
        }
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
                        ForEach(viewModel.messages) { message in
                            let isOwn = message.isOwn(userId: appState.currentUser?.id ?? "")
                            MessageBubble(message: message, isOwn: isOwn, palette: chatPalette,
                                          currentUserId: appState.currentUser?.id ?? "",
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
                                    onAnimationFinished: { playMessageSound(isOwn: isOwn) }
                                ))
                                // Nháy nền khi được nhảy tới từ kết quả tìm kiếm
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(chatPalette.primary.opacity(
                                            message.id == highlightedMessageId ? 0.16 : 0))
                                        .padding(.horizontal, 6)
                                )
                                .contextMenu {
                                    if !message.isDeleted {
                                        // Quick-react row: long-press already opens this menu,
                                        // so the emoji row lives at the top of it.
                                        ControlGroup {
                                            ForEach(ReactionEmoji.allCases, id: \.rawValue) { r in
                                                Button(r.rawValue) {
                                                    Task { await viewModel.sendReaction(messageId: message.id, emoji: r.rawValue) }
                                                }
                                            }
                                        }

                                        Button {
                                            replyingTo = message
                                        } label: {
                                            Label(bundle.loc("Reply"), systemImage: "arrowshape.turn.up.left")
                                        }
                                    }
                                    if isOwn && !message.isDeleted {
                                        Button(role: .destructive) {
                                            Task { await viewModel.recallMessage(message) }
                                        } label: {
                                            Label(bundle.loc("Unsend message"), systemImage: "arrow.uturn.backward")
                                        }
                                    }
                                }
                        }
                    }

                    if viewModel.isOtherTyping {
                        TypingIndicatorBubble()
                            .padding(.bottom, 4)
                    }

                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Đang jump thì các trang cũ vừa load không được kéo xuống đáy
                guard !isJumping else { return }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isOtherTyping) { _, _ in scrollToBottom(proxy: proxy) }
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
        let isConnected = connectVM.status == .accepted

        VStack(spacing: 12) {
            Spacer().frame(height: 60)

            // Avatar lớn
            ZStack {
                Circle()
                    .fill(Color(hex: otherUserAvatarColor))
                    .frame(width: 80, height: 80)
                Text(String(otherUserName.prefix(1)))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
            }

            // Display name
            Text(otherUserName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            // Trạng thái kết nối
            Text(isConnected
                 ? bundle.loc("You're connected — say hello 👋")
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

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            // "Replying to X" preview — clearable with an X button
            if let replyingTo {
                replyingToBar(replyingTo)
            }

            // Preview of the selected media before sending
            if !pendingMedia.isEmpty {
                mediaPreview
            }

            HStack(alignment: .bottom, spacing: 10) {
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

                TextField("", text: $inputText, prompt: Text("Message...", bundle: bundle), axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                    .onChange(of: inputText) { _, newVal in
                        let typing = !newVal.isEmpty
                        if typing != isTyping {
                            isTyping = typing
                            viewModel.sendTyping(typing)
                        }
                    }

                Button { sendPending() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(canSend
                                         ? chatPalette.primary
                                         : AppColors.textTertiary(colorScheme))
                        .padding(.bottom, 2)
                }
                .disabled(!canSend || viewModel.isSending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface(colorScheme))
    }

    /// "Replying to X" bar shown above the composer while `replyingTo` is set.
    private func replyingToBar(_ message: Message) -> some View {
        let isOwnReply = message.isOwn(userId: appState.currentUser?.id ?? "")
        let senderName = isOwnReply ? bundle.loc("You") : headerName
        let preview: String = {
            switch message.messageType {
            case .text:    return message.content ?? ""
            case .image:   return bundle.loc("Photo")
            case .video:   return bundle.loc("Video")
            case .meeting: return bundle.loc("Meeting")
            }
        }()

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(chatPalette.primary)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: bundle.loc("Replying to %@"), senderName))
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

    // MARK: - Helpers

    /// Nhảy tới một tin nhắn từ kết quả tìm kiếm: load lùi lịch sử tới khi
    /// thấy tin (tối đa 10 trang), cuộn tới giữa màn hình và nháy highlight.
    private func jumpToMessage(_ messageId: String) async {
        isJumping = true
        // Chờ sheet cài đặt đóng xong để cuộn không bị nuốt animation
        try? await Task.sleep(for: .milliseconds(300))
        let found = await viewModel.loadUntilFound(messageId: messageId)
        // Trang cũ vừa load hiển thị ngay, không chạy animation "tin mới"
        appearedMessageIDs.formUnion(viewModel.messages.map(\.id))
        guard found else {
            isJumping = false
            return
        }
        pendingScrollTarget = messageId
    }

    /// Mở viewer fullscreen cho ảnh/video của một bubble.
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

// MARK: - Pending media awaiting send

/// A picked image/video held in the composer before the user taps send.
private struct PendingMedia: Identifiable {
    let id = UUID()
    let url: URL
    let image: Image?   // nil for videos / non-image files (shown as a placeholder)
}

// MARK: - Transferable wrapper for photos picker

private struct MediaFileTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .item) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.copyItem(at: received.file, to: dest)
            return MediaFileTransferable(url: dest)
        }
    }
}

// MARK: - Message appear animation

/// Scales a message bubble up while sliding it in from the bottom the first time it
/// appears, then fires a completion callback (used to play a sound). Messages already
/// present in `appearedIDs` (loaded history) are shown instantly with no animation.
private struct MessageAppearModifier: ViewModifier {
    let id: String
    @Binding var appearedIDs: Set<String>
    let onAnimationFinished: () -> Void

    @State private var shown = false

    private let duration = 0.35

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.6, anchor: .bottom)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 20)
            .onAppear {
                if appearedIDs.contains(id) {
                    shown = true
                    return
                }
                appearedIDs.insert(id)
                withAnimation(.spring(response: duration, dampingFraction: 0.7)) {
                    shown = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    onAnimationFinished()
                }
            }
    }
}
