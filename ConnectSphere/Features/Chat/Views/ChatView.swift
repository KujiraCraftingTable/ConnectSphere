import SwiftUI
import PhotosUI

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

    @State private var viewModel: ChatViewModel
    @State private var inputText = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var isTyping = false
    @State private var showChatSettings = false
    @State private var navigateToProfile = false
    @State private var connectVM = ConnectViewModel()
    private let bottomID = "chatBottom"

    init(conversationId: String, otherUserId: String, otherUserName: String,
         otherUserAvatarColor: String, otherUserLocation: String? = nil,
         currentUserId: String, token: String) {
        self.conversationId = conversationId
        self.otherUserId = otherUserId
        self.otherUserName = otherUserName
        self.otherUserAvatarColor = otherUserAvatarColor
        self.otherUserLocation = otherUserLocation
        _viewModel = State(initialValue: ChatViewModel(
            conversationId: conversationId,
            currentUserId: currentUserId,
            token: token
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .background(AppColors.base(colorScheme))
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
                    Text(otherUserName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                .buttonStyle(.plain)
            }

            // Avatar → profile
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { navigateToProfile = true } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: otherUserAvatarColor))
                            .frame(width: 34, height: 34)
                        Text(String(otherUserName.prefix(1)))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(isPresented: $navigateToProfile) {
            UserProfileView(userId: otherUserId)
                .environment(appState)
        }
        .sheet(isPresented: $showChatSettings) {
            chatSettingsSheet
        }
        .task {
            viewModel.joinConversation()
            await viewModel.loadMessages()
            viewModel.markRead()
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
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await handlePickedMedia(item) }
        }
    }

    // MARK: - Chat settings placeholder

    private var chatSettingsSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer().frame(height: 20)
                Image(systemName: "gear")
                    .font(.system(size: 44))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Text("Cài đặt cuộc trò chuyện", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("Tính năng đang được phát triển", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Cài đặt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Xong")) { showChatSettings = false }
                        .foregroundColor(themeManager.theme.primary)
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
                            Task { await viewModel.loadOlderMessages() }
                        } label: {
                            Text("Tải tin nhắn cũ hơn", bundle: bundle)
                                .font(.system(size: 13))
                                .foregroundColor(themeManager.theme.primary)
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
                            MessageBubble(message: message, isOwn: isOwn)
                                .contextMenu {
                                    if isOwn && !message.isDeleted {
                                        Button(role: .destructive) {
                                            Task { await viewModel.recallMessage(message) }
                                        } label: {
                                            Label(bundle.loc("Thu hồi tin nhắn"), systemImage: "arrow.uturn.backward")
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
            .onChange(of: viewModel.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: viewModel.isOtherTyping) { _, _ in scrollToBottom(proxy: proxy) }
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
                 ? bundle.loc("Bạn đã kết nối với tài khoản này, hãy gửi lời chào 👋")
                 : bundle.loc("Bạn chưa kết nối với tài khoản này"))
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
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundColor(themeManager.theme.primary)
                    .padding(.bottom, 6)
            }

            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Nhắn tin...", bundle: bundle)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $inputText)
                    .font(.system(size: 15))
                    .frame(minHeight: 36, maxHeight: 120)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .scrollContentBackground(.hidden)
                    .onChange(of: inputText) { _, newVal in
                        let typing = !newVal.isEmpty
                        if typing != isTyping {
                            isTyping = typing
                            viewModel.sendTyping(typing)
                        }
                    }
            }
            .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))

            Button {
                let text = inputText
                inputText = ""
                isTyping = false
                viewModel.sendTyping(false)
                Task { await viewModel.sendText(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? AppColors.textTertiary(colorScheme)
                                     : themeManager.theme.primary)
                    .padding(.bottom, 2)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface(colorScheme))
    }

    // MARK: - Helpers

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func handlePickedMedia(_ item: PhotosPickerItem) async {
        guard let url = try? await item.loadTransferable(type: MediaFileTransferable.self) else { return }
        await viewModel.sendMedia(fileURL: url.url)
        pickerItem = nil
    }
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
