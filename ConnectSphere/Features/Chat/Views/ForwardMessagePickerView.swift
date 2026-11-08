import SwiftUI

/// Single-select picker over the user's conversations. Used by "Forward" in
/// the message long-press menu. Row style follows `ConversationListView`'s
/// `ConversationRow` (avatar + name, no preview line); selection/confirm
/// chrome follows `GroupMemberPickerView`'s pattern, simplified to a single
/// selection instead of a `Set`.
struct ForwardMessagePickerView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    /// The conversation the message is being forwarded FROM. Excluded from
    /// the picker (forwarding to the same chat doesn't make sense).
    let excludeConversationId: String
    /// Called with the chosen conversation's id; the sheet dismisses itself right after.
    let onConfirm: (String) -> Void

    @State private var viewModel = ConversationListViewModel()
    @State private var selectedId: String?

    private var pickableConversations: [Conversation] {
        viewModel.conversations.filter { $0.id != excludeConversationId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.conversations.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pickableConversations.isEmpty {
                    emptyState
                } else {
                    List(pickableConversations) { conversation in
                        Button {
                            selectedId = conversation.id
                        } label: {
                            row(conversation)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AppColors.surface(colorScheme))
                    }
                    .listStyle(.plain)
                }
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Forward to..."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Forward")) {
                        if let selectedId {
                            onConfirm(selectedId)
                        }
                        dismiss()
                    }
                    .disabled(selectedId == nil)
                    .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .task {
            guard let token = appState.authToken else { return }
            await viewModel.load(mode: appState.currentMode.rawValue, token: token)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let isSelected = selectedId == conversation.id
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: conversation.avatarColor)).frame(width: 44, height: 44)
                if conversation.isGroup {
                    Image(systemName: "person.3.fill")
                        .scaledFont(16, .semibold)
                        .foregroundColor(.white)
                } else {
                    Text(String(conversation.avatarName.prefix(1)))
                        .scaledFont(17, .bold)
                        .foregroundColor(.white)
                }
            }
            Text(conversation.displayName)
                .scaledFont(15, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .scaledFont(22)
                .foregroundColor(isSelected ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No other conversations to forward to", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
