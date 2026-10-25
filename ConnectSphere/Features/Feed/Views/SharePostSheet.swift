import SwiftUI

/// Sharing a post, Facebook-style: a note, the post, a row of your 20 most
/// recent chats to send it straight to (one tap each, "Sent" with a short
/// Undo; "⋯" opens every chat), and Share to Feed to repost it.
struct SharePostSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    let post: Post
    var onShared: (() -> Void)? = nil

    @State private var viewModel = SharePostViewModel()
    @State private var showAllChats = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(bundle.loc("Say something about this post..."), text: $viewModel.comment, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .padding(12)
                        .background(AppColors.base(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    postPreview

                    sendRow

                    Button {
                        Task {
                            guard await viewModel.share(.post(post.id), mode: appState.currentMode, token: token) else { return }
                            onShared?()
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isSharing {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.pencil")
                            }
                            Text("Share to Feed", bundle: bundle).fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSharing)

                    if viewModel.shareFailed {
                        Text("Couldn't share, please try again", bundle: bundle)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
            }
            .background(AppColors.surface(colorScheme))
            .navigationTitle(bundle.loc("Share post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showAllChats) {
                ShareRecipientsView(viewModel: viewModel, target: .post(post.id))
            }
            .task { await viewModel.loadRecipients(mode: appState.currentMode.rawValue, token: token) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The original post, condensed.
    private var postPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(user: post.sharedPost?.author ?? post.author, size: 28)
                Text((post.sharedPost?.author ?? post.author).name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            let previewText = post.sharedPost?.content ?? post.content
            if !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(previewText)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
    }

    /// The 20 most recent chats, then "⋯" for every chat.
    @ViewBuilder
    private var sendRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send to", bundle: bundle)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            if viewModel.isLoadingRecipients && viewModel.recipients.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            } else if viewModel.recipients.isEmpty {
                Text("No conversations yet", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(viewModel.recent) { conversation in
                            ShareRecipientTile(conversation: conversation,
                                               state: viewModel.sendStates[conversation.id],
                                               canUndo: viewModel.undoable.contains(conversation.id),
                                               onSend: { Task { await viewModel.send(.post(post.id), to: conversation, token: token) } },
                                               onUndo: { Task { await viewModel.undo(conversation, token: token) } })
                        }
                        Button { showAllChats = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                    .frame(width: Avatar.Size.lg.rawValue, height: Avatar.Size.lg.rawValue)
                                    .background(AppColors.elevated(colorScheme), in: Circle())
                                Text("More", bundle: bundle)
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(bundle.loc("All chats")))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// One chat in the "Send to" row: its avatar and name; tap sends, then it
/// shows "Sent" — with "Undo" for the first few seconds.
struct ShareRecipientTile: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let conversation: Conversation
    let state: SharePostViewModel.SendState?
    let canUndo: Bool
    let onSend: () -> Void
    let onUndo: () -> Void

    private var isSent: Bool { if case .sent = state { true } else { false } }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onSend) {
                Avatar(name: conversation.displayName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .lg)
                    .overlay(alignment: .bottomTrailing) {
                        if isSent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white, themeManager.theme.primary)
                        } else if state == .sending {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    .opacity(isSent ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(state == .sending || isSent)

            Text(conversation.displayName)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 70)

            if canUndo {
                Button(bundle.loc("Undo"), action: onUndo)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
            } else if isSent {
                Text("Sent", bundle: bundle)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            } else if state == .failed {
                Text("Retry", bundle: bundle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .frame(width: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(conversation.displayName))
        .accessibilityValue(Text(isSent ? bundle.loc("Sent") : ""))
    }
}

/// Every chat, searchable, each with Send / Sent — "⋯" in the share sheet.
struct ShareRecipientsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var viewModel: SharePostViewModel
    let target: ShareTarget

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List(viewModel.searched) { conversation in
            HStack(spacing: 12) {
                Avatar(name: conversation.displayName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .md)
                Text(conversation.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                sendButton(conversation)
            }
            .listRowBackground(AppColors.surface(colorScheme))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.surface(colorScheme))
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(bundle.loc("Search chats")))
        .navigationTitle(bundle.loc("Send to"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sendButton(_ conversation: Conversation) -> some View {
        switch viewModel.sendStates[conversation.id] {
        case .sending:
            ProgressView()
        case .sent:
            if viewModel.undoable.contains(conversation.id) {
                Button(bundle.loc("Undo")) { Task { await viewModel.undo(conversation, token: token) } }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.bordered)
            } else {
                Label(bundle.loc("Sent"), systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        case .failed, nil:
            Button(bundle.loc(viewModel.sendStates[conversation.id] == .failed ? "Retry" : "Send")) {
                Task { await viewModel.send(target, to: conversation, token: token) }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(themeManager.theme.primary)
        }
    }
}
