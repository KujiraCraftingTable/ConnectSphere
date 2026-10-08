import SwiftUI

/// What the space name/colour sheet is doing.
enum SpaceEditorTarget: Identifiable {
    case create
    case edit(ChatSpace)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let space): return space.id
        }
    }
}

/// A space's name as a small tinted tag (Spaces-off list, chat settings).
struct SpaceTag: View {
    @Environment(\.colorScheme) private var colorScheme
    let space: ChatSpace

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(space.color.color).frame(width: 6, height: 6)
            Text(space.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(AppColors.textSecondary(colorScheme))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(space.color.color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A switch with its control on the leading side and the label after it.
struct LeadingSwitchStyle: ToggleStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .tint(tint)
                .fixedSize()
            // The label is part of the control: tapping "Spaces" flips it too.
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// Archived chats, with swipe-to-unarchive. A new message brings a chat back
/// to the main list on its own.
struct ArchivedChatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: ConversationListViewModel
    let onOpen: (Conversation) -> Void

    var body: some View {
        Group {
            if viewModel.archived.isEmpty {
                EmptyStateView(systemImage: "archivebox",
                               title: bundle.loc("No archived chats"),
                               message: bundle.loc("Swipe a chat left and tap Archive to tidy it away. A new message brings it back."))
            } else {
                List {
                    Section {
                        ForEach(viewModel.archived) { conversation in
                            Button { onOpen(conversation) } label: {
                                ConversationRow(conversation: conversation,
                                                currentUserId: appState.currentUser?.id ?? "",
                                                accentColor: themeManager.theme.primary)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(AppColors.surface(colorScheme))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in ConversationRow.textInset }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.setArchived(conversation, false, token: appState.authToken ?? "") }
                                } label: {
                                    Label(bundle.loc("Unarchive"), systemImage: "tray.and.arrow.up.fill")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, AppSpacing.sm, for: .scrollContent)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Archived chats"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Chats from people who aren't your friends yet. Swipe to accept (moves the
/// chat to your inbox) or delete; opening one lets you read it before deciding.
struct WaitingChatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: ConversationListViewModel
    let onOpen: (Conversation) -> Void

    @State private var pendingDelete: Conversation?

    var body: some View {
        Group {
            if viewModel.waiting.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: bundle.loc("Nothing waiting"),
                               message: bundle.loc("When someone who isn't your friend messages you, it waits here until you accept."))
            } else {
                List {
                    Section {
                        ForEach(viewModel.waiting) { conversation in
                            Button { onOpen(conversation) } label: {
                                ConversationRow(conversation: conversation,
                                                currentUserId: appState.currentUser?.id ?? "",
                                                accentColor: themeManager.theme.primary)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(AppColors.surface(colorScheme))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in ConversationRow.textInset }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.accept(conversation, token: appState.authToken ?? "") }
                                } label: {
                                    Label(bundle.loc("Accept"), systemImage: "checkmark.circle.fill")
                                }
                                .tint(.green)
                                Button(role: .destructive) { pendingDelete = conversation } label: {
                                    Label(bundle.loc("Delete"), systemImage: "trash.fill")
                                }
                            }
                        }
                    } footer: {
                        Text("They can send up to 3 messages until you accept. Replying also accepts.", bundle: bundle)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, AppSpacing.sm, for: .scrollContent)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Waiting"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(bundle.loc("Delete this chat?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { conversation in
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { await viewModel.delete(conversation, token: appState.authToken ?? "") }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Its messages are removed for you only. It comes back if a new message arrives.", bundle: bundle)
        }
    }
}
