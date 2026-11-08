import SwiftUI

/// Sharing a post, Facebook-style, in three steps inside one sheet:
/// - **Start**: you, "Say something about this…" and Share now; below it, your
///   recent chats.
/// - **Post**: tapping "Say something" opens the note to write before sharing to
///   your feed. Back returns to Start.
/// - **Send**: tapping a chat picks it and opens the message step: the chats
///   (tap more to add them), a message, and Send. Back returns to Start.
/// Marketplace items are passed on by message only, so they skip the feed part.
struct SharePostSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    let post: Post
    var onShared: (() -> Void)? = nil

    private enum Step { case start, post, send }

    @State private var viewModel = SharePostViewModel()
    @State private var step: Step = .start
    @State private var showAllChats = false
    /// The sheet is as tall as what it shows: no empty full-screen sheet.
    @State private var contentHeight: CGFloat = 320
    @FocusState private var noteFocused: Bool

    private var token: String { appState.authToken ?? "" }
    private var isListing: Bool { post.postType == .listing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .start:
                        if !isListing { composerCard(writing: false) }
                        sendSection
                    case .post:
                        header(bundle.loc("Share"))
                        composerCard(writing: true)
                    case .send:
                        header(bundle.loc("Send in a message"))
                        recipientRow
                        messageField
                        ShareSendButton(viewModel: viewModel) {
                            guard await viewModel.sendSelected(.post(post.id), token: token) else { return }
                            onShared?()
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .animation(.easeInOut(duration: 0.2), value: step)
            }
            .background(AppColors.base(colorScheme))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showAllChats) {
                ShareRecipientsView(viewModel: viewModel)
            }
            .task { await viewModel.loadRecipients(mode: appState.currentMode.rawValue, token: token) }
        }
        // The sheet already adds room for the drag indicator and the bottom
        // safe area, so the content height alone is about right.
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Steps

    private func go(to next: Step) {
        // A note started for the feed isn't a message, and the other way round.
        if next == .start { viewModel.comment = "" }
        step = next
        noteFocused = next != .start
    }

    /// "< Share" / "< Send in a message": back to the start.
    private func header(_ title: String) -> some View {
        Button { go(to: .start) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").scaledFont(18, .semibold)
                Text(title).scaledFont(20, .bold)
            }
            .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(bundle.loc("Back")))
    }

    /// You, the note, Share now. On the start step the note is a placeholder
    /// that opens the post step; on the post step it's the real field.
    private func composerCard(writing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let me = appState.currentUser {
                HStack(spacing: 12) {
                    AvatarView(user: me, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me.name).scaledFont(16, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Text("Feed", bundle: bundle).scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            }
            if writing {
                TextField(bundle.loc("Say something about this..."), text: $viewModel.comment, axis: .vertical)
                    .scaledFont(16)
                    .lineLimit(1...6)
                    .focused($noteFocused)
            } else {
                Button { go(to: .post) } label: {
                    Text("Say something about this...", bundle: bundle)
                        .scaledFont(16)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Only while writing: on the start step it would push the chats off a half sheet.
            if writing { postPreview }
            HStack {
                Spacer()
                Button {
                    Task {
                        guard await viewModel.share(.post(post.id), mode: appState.currentMode, token: token) else { return }
                        onShared?()
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isSharing { ProgressView().tint(.white) }
                        Text("Share now", bundle: bundle).scaledFont(16, .semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSharing)
            }
            if viewModel.shareFailed {
                Text("Couldn't share, please try again", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(.red)
            }
        }
        .padding(16)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The original post, condensed.
    private var postPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(user: post.sharedPost?.author ?? post.author, size: 28)
                Text((post.sharedPost?.author ?? post.author).name)
                    .scaledFont(14, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            let rawText = post.sharedPost?.content ?? post.content
            // Markdown posts show their words, not the ** and _ marks.
            let previewText = (post.sharedPost?.isMarkdown ?? post.isMarkdown) ? MarkdownFormatter.plain(rawText) : rawText
            if !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(previewText)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
    }

    /// Start step: "Send in a message" and the chats. Tapping one picks it and
    /// moves to the send step.
    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send in a message", bundle: bundle)
                .scaledFont(18, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            recipientRow
        }
    }

    private var messageField: some View {
        TextField(bundle.loc("Write a message..."), text: $viewModel.comment, axis: .vertical)
            .scaledFont(16)
            .lineLimit(1...4)
            .focused($noteFocused)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppColors.surface(colorScheme), in: Capsule())
    }

    /// The 20 most recent chats, then "⋯" for every chat.
    @ViewBuilder
    private var recipientRow: some View {
        if viewModel.isLoadingRecipients && viewModel.recipients.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 90)
        } else if viewModel.recipients.isEmpty {
            Text("No conversations yet", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(viewModel.recent) { conversation in
                        ShareRecipientTile(conversation: conversation,
                                           isSelected: viewModel.isSelected(conversation),
                                           onTap: {
                                               viewModel.toggle(conversation)
                                               if step == .start { go(to: .send) }
                                           })
                    }
                    Button {
                        if step == .start { go(to: .send) }
                        showAllChats = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "ellipsis")
                                .scaledFont(20, .semibold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .frame(width: Avatar.Size.lg.rawValue, height: Avatar.Size.lg.rawValue)
                                .background(AppColors.elevated(colorScheme), in: Circle())
                            Text("More", bundle: bundle)
                                .scaledFont(12)
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
                Avatar(name: conversation.avatarName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .lg)
                    .padding(3)
                    .overlay(Circle().stroke(isSelected ? themeManager.theme.primary : .clear, lineWidth: 2.5))
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .scaledFont(22)
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
                    .scaledFont(13)
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
                Avatar(name: conversation.avatarName, colorHex: conversation.avatarColor,
                       imageURL: conversation.avatarUrl, size: .md)
                Text(conversation.displayName)
                    .scaledFont(15, .semibold)
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
            .scaledFont(22)
            .foregroundStyle(picked ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
    }
}
