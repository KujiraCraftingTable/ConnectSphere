import SwiftUI

/// Pinned messages for a conversation (server caps at 10). Follows
/// `ChatMessageSearchView`'s exact shape: settings viewmodel + `onSelect`
/// callback the caller uses to jump to the tapped message. Reused both as a
/// pushed screen from `ChatSettingsView`'s "Pinned messages" row and as a
/// standalone sheet from `ChatView`'s pinned-banner.
struct ChatPinnedMessagesView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let viewModel: ChatSettingsViewModel
    /// Tapping a pin. The parent closes the sheet/settings then jumps to this message
    var onSelect: ((PinnedMessage) -> Void)? = nil

    /// The pin awaiting unpin confirmation. Set by both the swipe action and the pin.slash
    /// button; nil means the dialog is closed. Tracked by the specific pin (not a single Bool)
    /// because this is a list, not a single toggle.
    @State private var pendingUnpin: PinnedMessage? = nil

    // MARK: - Body
    var body: some View {
        Group {
            if viewModel.isLoadingPins && viewModel.pinnedMessages.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.pinnedMessages.isEmpty {
                emptyState
            } else {
                List(viewModel.pinnedMessages) { pin in
                    Button {
                        onSelect?(pin)
                    } label: {
                        pinRow(pin)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppColors.surface(colorScheme))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingUnpin = pin
                        } label: {
                            Label(bundle.loc("Unpin"), systemImage: "pin.slash")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Pinned messages"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadPins() }
        .alert(
            bundle.loc("Unpin this message?"),
            isPresented: Binding(get: { pendingUnpin != nil }, set: { if !$0 { pendingUnpin = nil } })
        ) {
            Button(bundle.loc("Unpin"), role: .destructive) {
                if let pin = pendingUnpin {
                    Task { await viewModel.unpinMessage(pin.id) }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("It will be removed from the pinned list.", bundle: bundle)
        }
    }

    // MARK: - Pin rows
    private func pinRow(_ pin: PinnedMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pin.senderName)
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(pin.preview)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                Text(String(format: bundle.loc("Pinned by %@"), pinnedByName(pin))
                     + " · " + pin.pinnedAt.dayMonthTime)
                    .scaledFont(11)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                if let expiresAt = pin.expiresAt {
                    Text(String(format: bundle.loc("Expires %@"), expiresAt.dayMonthYear))
                        .scaledFont(11)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }

            Spacer()

            Button {
                pendingUnpin = pin
            } label: {
                Image(systemName: "pin.slash")
                    .scaledFont(14)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .accessibilityLabel(Bundle.app.loc("Unpin"))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// Resolves who pinned this message: "You", the group roster, or the 1:1
    /// other person, mirrors `ChatView.senderDisplayName(for:)`'s fallback style.
    private func pinnedByName(_ pin: PinnedMessage) -> String {
        if pin.pinnedBy == appState.currentUser?.id { return bundle.loc("You") }
        return viewModel.displayName(forUserId: pin.pinnedBy) ?? bundle.loc("Someone")
    }

    // MARK: - Empty state
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pin.slash")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No pinned messages yet", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
