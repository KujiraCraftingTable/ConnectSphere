import SwiftUI
import Observation

/// The chats the floating window's "+" can add: accepted ones only (people
/// and groups, not Waiting requests), not archived, newest first.
@MainActor
@Observable
final class FloatingChatAddViewModel {
    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The chat being joined and loaded after a tap.
    private(set) var addingID: String?
    var query = ""

    private let repository = MessageRepository()

    var shown: [Conversation] { Self.addable(conversations, query: query) }

    static func addable(_ conversations: [Conversation], query: String) -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return conversations
            .filter { $0.requestState == nil && !$0.isArchived }
            .filter { needle.isEmpty || $0.displayName.localizedStandardContains(needle) }
            .sorted { ($0.lastMessageAt ?? $0.updatedAt) > ($1.lastMessageAt ?? $1.updatedAt) }
    }

    func load(mode: String, token: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            conversations = try await repository.fetchConversations(mode: mode, token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Floats `conversation`; returns the chat closed to make room, if any.
    func add(_ conversation: Conversation, to presenter: FloatingChatPresenter,
             currentUserId: String, token: String) async -> FloatingBubbleState? {
        addingID = conversation.id
        defer { addingID = nil }
        return await presenter.add(conversation, currentUserId: currentUserId, token: token)
    }
}

/// Picks a chat to add to the floating window without leaving the screen
/// you're on. Chats already floating show a check; tapping one shows it.
struct FloatingChatAddSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(UndoToastPresenter.self) private var toastPresenter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    let presenter: FloatingChatPresenter
    @State private var viewModel = FloatingChatAddViewModel()

    private var token: String { appState.authToken ?? "" }
    private var currentUserId: String { appState.currentUser?.id ?? "" }

    var body: some View {
        NavigationStack {
            List {
                if presenter.bubbles.count >= FloatingChatPresenter.maxChats {
                    Section {
                        Text("Up to 4 chats float at once. Adding one closes the chat you used longest ago.", bundle: bundle)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                ForEach(viewModel.shown) { conversation in
                    row(conversation)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $viewModel.query, prompt: Text("Search chats", bundle: bundle))
            .overlay { state }
            .navigationTitle(bundle.loc("Add to floating chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
        .task { await viewModel.load(mode: appState.currentMode.rawValue, token: token) }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var state: some View {
        if viewModel.isLoading && viewModel.conversations.isEmpty {
            ProgressView()
        } else if let error = viewModel.errorMessage, viewModel.conversations.isEmpty {
            VStack(spacing: 10) {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                Button(bundle.loc("Retry")) {
                    Task { await viewModel.load(mode: appState.currentMode.rawValue, token: token) }
                }
            }
            .padding(.horizontal, 32)
        } else if !viewModel.isLoading && viewModel.shown.isEmpty {
            Text("No conversations yet", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let floating = presenter.hasBubble(for: conversation.id)
        return Button { pick(conversation) } label: {
            HStack(spacing: 12) {
                Avatar(name: conversation.displayName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .md)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    Text(conversation.previewText(currentUserId: currentUserId))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if viewModel.addingID == conversation.id {
                    ProgressView()
                } else if floating {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(themeManager.theme.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.addingID != nil)
        .accessibilityAddTraits(floating ? .isSelected : [])
    }

    private func pick(_ conversation: Conversation) {
        Task {
            let closed = await viewModel.add(conversation, to: presenter, currentUserId: currentUserId, token: token)
            if let closed {
                toastPresenter.show(message: String(format: bundle.loc("Closed chat with %@ to make room"),
                                                    closed.peer.name))
            }
            dismiss()
        }
    }
}
