import SwiftUI

/// Sheet presentation for the in-app AI assistant: a scrollable list of chat
/// bubbles (user right-aligned filled, assistant left-aligned) plus a bottom
/// text input bar. Matches Chat's visual style (bubble corner radius, fonts,
/// colors) but as new, simpler view code, NOT a reuse of `MessageBubble`,
/// which is heavily coupled to the real messaging system.
struct AssistantChatView: View {
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    let appState: AppState
    let themeManager: ThemeManager

    /// Owned by `MainTabView`, not by this sheet. `.sheet` destroys its content
    /// on dismiss, so a view model created here would take the conversation
    /// with it, and "Take me there" dismisses, meaning acting on any
    /// suggestion used to wipe the chat.
    let viewModel: AssistantViewModel

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                inputBar
            }
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationTitle(bundle.loc("Assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Dismissing no longer clears the conversation, so there has
                // to be an explicit way to reset it.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Clear")) { viewModel.clearConversation() }
                        .disabled(viewModel.messages.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
            .task { inputFocused = true }
        }
        // "dark mode" / "light mode" asked here must restyle this open sheet.
        .preferredColorScheme(appState.appearanceMode.resolvedColorScheme)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        AssistantBubbleView(
                            message: message,
                            palette: themeManager.theme,
                            onNavigate: { target in
                                appState.pendingAssistantNavigation = target
                                dismiss()
                            },
                            onConfirmLogout: { viewModel.confirmLogout(messageId: message.id) },
                            onCancelLogout: { viewModel.cancelLogout(messageId: message.id) },
                            onConfirmIntent: { viewModel.confirmIntent($0, messageId: message.id) },
                            onCancelIntent: { viewModel.cancelIntent(messageId: message.id) },
                            onPickTopic: { viewModel.showTopic($0, messageId: message.id) },
                            onUndo: { viewModel.undo($0, messageId: message.id) }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty state

    /// Short welcome line + a few tappable example prompts. Kept minimal
    /// (full quick-command suggestion chips as a discoverability feature is
    /// noted as future work; this is just enough to not stare at a blank sheet).
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .scaledFont(34)
                .foregroundColor(themeManager.theme.primary)
            Text("Ask me to change a setting or find something in the app.", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                suggestionChip(bundle.loc("Switch to dark mode"))
                suggestionChip(bundle.loc("How do I change my password?"))
                suggestionChip(bundle.loc("Go to settings"))
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// Sends exactly the label that is displayed. Previously the label was
    /// localized but the sent text was hardcoded English, so a Vietnamese chip
    /// only worked because the registry happened to hold both languages.
    private func suggestionChip(_ label: String) -> some View {
        Button { viewModel.send(label) } label: {
            Text(label)
                .scaledFont(13, .medium)
                .foregroundColor(themeManager.theme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(themeManager.theme.primary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $inputText, prompt: Text("Ask the assistant...", bundle: bundle), axis: .vertical)
                .scaledFont(15)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)
                .onSubmit(sendCurrentInput)
                .accessibilityIdentifier(AXID.Assistant.input)

            Button(action: sendCurrentInput) {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(32)
                    .foregroundColor(canSend ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            }
            .accessibilityLabel(Bundle.app.loc("Send"))
            .accessibilityIdentifier(AXID.Assistant.sendButton)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface(colorScheme))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCurrentInput() {
        let text = inputText
        inputText = ""
        viewModel.send(text)
    }
}

// MARK: - Bubble

private struct AssistantBubbleView: View {
    let message: AssistantMessage
    let palette: ThemePalette
    let onNavigate: (AssistantNavigationTarget) -> Void
    let onConfirmLogout: () -> Void
    let onCancelLogout: () -> Void
    let onConfirmIntent: (AssistantIntent) -> Void
    let onCancelIntent: () -> Void
    let onPickTopic: (AssistantGuidanceTopic) -> Void
    let onUndo: (AssistantIntent) -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isFromUser { Spacer(minLength: 50) }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .scaledFont(15)
                    .foregroundColor(message.isFromUser ? .white : AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromUser ? AnyShapeStyle(palette.primary) : AnyShapeStyle(AppColors.surface(colorScheme)))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let action = message.action {
                    actionView(action)
                }
            }

            if !message.isFromUser { Spacer(minLength: 50) }
        }
    }

    @ViewBuilder
    private func actionView(_ action: AssistantMessageAction) -> some View {
        switch action {
        case .navigate(let target):
            Button { onNavigate(target) } label: {
                Label {
                    Text("Take me there", bundle: bundle)
                } icon: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .scaledFont(13, .semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AXID.Assistant.takeMeThere)

        case .confirmLogout:
            HStack(spacing: 8) {
                Button(bundle.loc("Yes, log out")) { onConfirmLogout() }
                    .scaledFont(13, .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red)
                    .clipShape(Capsule())

                Button(bundle.loc("Cancel")) { onCancelLogout() }
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppColors.elevated(colorScheme))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .confirmIntent(let intent):
            HStack(spacing: 8) {
                Button(bundle.loc("Yes")) { onConfirmIntent(intent) }
                    .scaledFont(13, .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(palette.primary)
                    .clipShape(Capsule())

                Button(bundle.loc("No")) { onCancelIntent() }
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppColors.elevated(colorScheme))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .undo(let intent):
            Button { onUndo(intent) } label: {
                Label {
                    Text("Undo", bundle: bundle)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .scaledFont(13, .semibold)
                .foregroundColor(palette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.primary.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AXID.Assistant.undo)

        case .suggestTopics(let topics):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(topics, id: \.self) { topic in
                    Button { onPickTopic(topic) } label: {
                        Text(bundle.loc(topic.titleKey))
                            .scaledFont(13, .semibold)
                            .foregroundColor(palette.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(palette.primary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
