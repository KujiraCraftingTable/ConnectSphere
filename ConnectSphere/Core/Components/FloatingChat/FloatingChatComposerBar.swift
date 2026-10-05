import SwiftUI
import PhotosUI

/// Full-width message composer for the floating chat, docked directly above
/// the keyboard — rendered once by `FloatingChatOverlay` for whichever bubble
/// is composing.
///
/// It deliberately does *not* live inside `FloatingChatBubbleView`. As an
/// overlay on that 132pt-wide card the field was both hard to read (12pt text)
/// and drawn detached from the card entirely, while the card itself sat behind
/// the keyboard. Docking the bar here gives the same 15pt field as
/// `ChatView.inputBar` and makes detaching structurally impossible, since the
/// bar is no longer positioned relative to a freely-draggable card.
///
/// Deliberately text and photos only — "keep the conversation going", not the
/// full `ChatView` composer. Voice, meeting proposals and replies stay in the
/// full chat, which a double-tap on the bubble restores.
struct FloatingChatComposerBar: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let bubble: FloatingBubbleState
    let presenter: FloatingChatPresenter

    @State private var pickerItems: [PhotosPickerItem] = []
    @FocusState private var isInputFocused: Bool
    /// Per-conversation quick-emoji preference, shared with `ChatView`'s send
    /// button and set in Chat settings — see `quickEmojiStorageKey`.
    @AppStorage private var quickEmoji: String

    init(bubble: FloatingBubbleState, presenter: FloatingChatPresenter) {
        self.bubble = bubble
        self.presenter = presenter
        _quickEmoji = AppStorage(
            wrappedValue: QuickEmoji.defaultValue,
            quickEmojiStorageKey(conversationId: bubble.id)
        )
    }

    /// `bubble` is a reference type, so the draft is bound through explicit
    /// get/set rather than `@Bindable` — it keeps the draft on the bubble
    /// (surviving the bar closing and reopening) without shadowing `bubble`
    /// inside `body`.
    private var draftBinding: Binding<String> {
        Binding(get: { bubble.draftText }, set: { bubble.draftText = $0 })
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 10,
                         matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundColor(themeManager.theme.primary)
                    .padding(.bottom, 6)
            }

            TextField("", text: draftBinding,
                      prompt: Text("Message...", bundle: bundle), axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppColors.borderStrong(colorScheme), lineWidth: 1)
                )
                .onSubmit(sendDraft)

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface(colorScheme))
        .overlay(alignment: .top) { Divider() }
        .onAppear { isInputFocused = true }
        // The overlay lifts the composing bubble to clear this bar, so it needs
        // the bar's live top edge — reported here rather than derived from a
        // keyboard-height notification, which would have to guess the bar's
        // own height on top of it.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            presenter.composerTopY = top
        }
        .onDisappear { presenter.composerTopY = nil }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPickedMedia(items) }
        }
    }

    /// Never greyed out — a grey control reads as "this can't be used", and
    /// this one always can: with text it's the arrow, empty it's a one-tap
    /// quick-emoji send (Messenger's behaviour).
    private var sendButton: some View {
        Button {
            if canSend { sendDraft() } else { sendQuickEmoji() }
        } label: {
            Group {
                if canSend {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(themeManager.theme.primary)
                } else {
                    Text(quickEmoji)
                        .font(.system(size: 27))
                }
            }
            .frame(width: 34, height: 34)
            .padding(.bottom, 2)
        }
        .disabled(bubble.viewModel.isSending)
    }

    private var canSend: Bool {
        !bubble.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the typed draft and clears it.
    private func sendDraft() {
        let trimmed = bubble.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bubble.draftText = ""
        Task { await bubble.viewModel.sendText(trimmed) }
    }

    /// Sends the configured quick emoji as an ordinary text message — there is
    /// no sticker message type (`MessageType` is text/image/video/meeting/
    /// voice, and the DB CHECK allows only those), so one-tap send is simply a
    /// very short text.
    private func sendQuickEmoji() {
        Task { await bubble.viewModel.sendText(quickEmoji) }
    }

    /// Sends each picked photo/video immediately — the mini composer has no
    /// staging strip to preview them in, unlike `ChatView`'s `mediaPreview`.
    private func sendPickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let media = try? await item.loadTransferable(type: MediaFileTransferable.self) else { continue }
            await bubble.viewModel.sendMedia(fileURL: media.url)
        }
        pickerItems = []
    }
}
