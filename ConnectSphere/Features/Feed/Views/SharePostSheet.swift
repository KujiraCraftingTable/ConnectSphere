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
                    TextField(bundle.loc(post.postType == .listing ? "Say something about this item..." : "Say something about this post..."), text: $viewModel.comment, axis: .vertical)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .padding(12)
                        .background(AppColors.base(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    postPreview

                    sendRow

                    ShareSendButton(viewModel: viewModel) {
                        guard await viewModel.sendSelected(.post(post.id), token: token) else { return }
                        onShared?()
                        dismiss()
                    }

                    // Marketplace items are passed on by message only, never reposted.
                    if post.postType != .listing {
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
                    }

                    if viewModel.shareFailed {
                        Text("Couldn't share, please try again", bundle: bundle)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
            }
            .background(AppColors.surface(colorScheme))
            .navigationTitle(bundle.loc(post.postType == .listing ? "Send in a message" : "Share post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showAllChats) {
                ShareRecipientsView(viewModel: viewModel)
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
                                               isSelected: viewModel.isSelected(conversation),
                                               onTap: { viewModel.toggle(conversation) })
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

/// One chat in the "Send to" row: its avatar and name. Tapping only picks it
/// (a ring and a tick); the sheet's Send button sends to everyone picked.
struct ShareRecipientTile: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let conversation: Conversation
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Avatar(name: conversation.displayName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .lg)
                    .padding(3)
                    .overlay(Circle().stroke(isSelected ? themeManager.theme.primary : .clear, lineWidth: 2.5))
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white, themeManager.theme.primary)
                        }
                    }
                Text(conversation.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 76)
        .accessibilityLabel(Text(conversation.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Send" / "Send to 3", sends to every picked chat at once.
struct ShareSendButton: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: SharePostViewModel
    let send: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { Task<Void, Never>(name: nil) { await send() } } label: {
                HStack(spacing: 8) {
                    if viewModel.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(viewModel.selected.isEmpty ? bundle.loc("Send")
                         : String(format: bundle.loc("Send to %lld"), viewModel.selected.count))
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(themeManager.theme.primary.opacity(viewModel.selected.isEmpty ? 0.4 : 1),
                            in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.selected.isEmpty || viewModel.isSending)
            if viewModel.sendFailed {
                Text("Couldn't send to some chats", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.danger(colorScheme))
            }
        }
    }
}

/// Every chat, searchable, each tapped to pick it, "⋯" in the share sheet.
/// Picks are shared with the sheet's row; Send there sends to them all.
struct ShareRecipientsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var viewModel: SharePostViewModel

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
                tick(conversation)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.toggle(conversation) }
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

    private func tick(_ conversation: Conversation) -> some View {
        let picked = viewModel.isSelected(conversation)
        return Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(picked ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
    }
}
