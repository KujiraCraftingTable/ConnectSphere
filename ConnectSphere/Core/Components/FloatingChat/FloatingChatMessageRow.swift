import AVFoundation
import SwiftUI

/// One message in the floating chat window. Text sits in a small bubble;
/// photos and videos show as themselves. An album as each of its photos on
/// its own, a video playing (with sound) while it's the one in view; a voice
/// message plays on tap; a meeting shows its card, with RSVP in groups
/// (rescheduling and cancelling stay in the full chat). One sound plays at a
/// time across the window (`FloatingChatPresenter.playingMediaID`).
struct FloatingChatMessageRow: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let message: Message
    let bubble: FloatingBubbleState
    /// This chat's own theme (shared by everyone in it), like the full chat.
    private var chatAccent: Color { (ThemePalette.byId(bubble.viewModel.chatThemeId) ?? themeManager.theme).primary }
    let presenter: FloatingChatPresenter
    /// The page's content width.
    let width: CGFloat

    @State private var viewer: ViewerTarget?
    @State private var openedPost: OpenedSharedPost?

    private struct ViewerTarget: Identifiable {
        let id = UUID()
        let items: [ChatMediaViewerItem]
        let start: Int
    }

    private var isOwn: Bool { message.isOwn(userId: bubble.currentUserId) }
    private var mediaWidth: CGFloat { width * 0.82 }

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
            if !message.isDeleted, message.replyToMessageId != nil, let replied = message.repliedMessage {
                replyQuote(replied)
            }
            if message.isDeleted {
                textBubble(bundle.loc("Message unsent"), muted: true)
            } else {
                switch message.messageType {
                case .image, .video, .album:
                    ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                        if item.isVideo {
                            FloatingChatVideo(id: "\(message.id)-\(index)", url: item.url, bubble: bubble,
                                              presenter: presenter, width: mediaWidth)
                        } else {
                            photo(item.url)
                                .onTapGesture { openViewer(at: index) }
                        }
                    }
                    if let caption = message.content, !caption.isEmpty {
                        textBubble(caption)
                    }
                case .voice:
                    VoiceMessagePlayer(message: message, isOwn: isOwn, accent: chatAccent,
                                       compact: true,
                                       isActive: presenter.playingMediaID == message.id,
                                       onStart: {
                                           presenter.markSeen(bubble)
                                           presenter.playingMediaID = message.id
                                       })
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(width: width * 0.85)
                        .background(isOwn ? chatAccent.opacity(0.9) : AppColors.elevated(colorScheme),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .meeting:
                    if let proposal = message.meetingProposal {
                        MeetingProposalCard(
                            proposal: proposal, isOwn: isOwn, isGroup: bubble.viewModel.isGroup,
                            currentUserId: bubble.currentUserId, accent: chatAccent,
                            compact: true,
                            onRespond: { status in
                                presenter.markSeen(bubble)
                                Task { await bubble.viewModel.respondToMeeting(messageId: message.id, status: status) }
                            }
                        )
                        .frame(width: width * 0.9)
                    } else {
                        textBubble("📅 " + bundle.loc("Meeting"))
                    }
                case .poll:
                    if let poll = message.poll {
                        ChatPollCard(question: message.content ?? "", poll: poll,
                                     currentUserId: bubble.currentUserId, accent: chatAccent,
                                     compact: true,
                                     onVote: { optionId in
                                         presenter.markSeen(bubble)
                                         Task { await bubble.viewModel.tapPollOption(messageId: message.id, optionId: optionId) }
                                     })
                            .frame(width: width * 0.9)
                    } else {
                        textBubble("📊 " + (message.content ?? ""))
                    }
                case .post:
                    if let note = message.content, !note.isEmpty { textBubble(note) }
                    ChatSharedPostCard(
                        state: message.sharedPostId.flatMap { bubble.viewModel.sharedPosts[$0] } ?? (message.sharedPostId == nil ? .unavailable : nil),
                        compact: true,
                        accent: chatAccent,
                        onAppear: { Task { await bubble.viewModel.loadSharedPost(message.sharedPostId) } },
                        onOpen: { post in
                            presenter.markSeen(bubble)
                            openedPost = OpenedSharedPost(id: post.id)
                        })
                        // Narrower than the window, so there's room beside it to tap and reply.
                        .frame(width: width * 0.75)
                case .community:
                    // The mini window has no room for the card; the chat shows it.
                    textBubble("👥 " + ((message.content?.isEmpty == false ? message.content : nil) ?? bundle.loc("Shared a community")))
                case .legitCheck:
                    textBubble("✅ " + bundle.loc("Review card"))
                case .text, .unknown:
                    textBubble(message.content ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
        .fullScreenCover(item: $viewer) { target in
            ChatMediaViewerView(items: target.items, startIndex: target.start)
        }
        .sheet(item: $openedPost) { route in
            NavigationStack { PostDetailView(postId: route.id) }
        }
    }

    // MARK: Media

    private struct MediaItem {
        let url: URL
        let isVideo: Bool
    }

    /// The message's photos and videos in order. One for a photo or video
    /// message, each of an album's items for an album.
    private var media: [MediaItem] {
        if message.messageType == .album {
            return (message.mediaItems ?? []).compactMap { item in
                APIConfig.mediaURL(item.url).map { MediaItem(url: $0, isVideo: item.type == "video") }
            }
        }
        guard let url = message.absoluteMediaURL() else { return [] }
        return [MediaItem(url: url, isVideo: message.messageType == .video)]
    }

    private func photo(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
                    .frame(maxWidth: mediaWidth, maxHeight: mediaWidth * 1.4)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppColors.elevated(colorScheme))
                    .frame(width: mediaWidth, height: mediaWidth * 0.75)
                    .overlay {
                        if phase.error == nil { ProgressView() } else { Image(systemName: "photo") }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isImage)
    }

    /// Opening a photo is looking at the chat too, so it counts as seen.
    private func openViewer(at index: Int) {
        presenter.markSeen(bubble)
        let items = media.enumerated().map { offset, item in
            ChatMediaViewerItem(id: "\(message.id)-\(offset)", url: item.url, isVideo: item.isVideo)
        }
        viewer = ViewerTarget(items: items, start: index)
    }

    // MARK: Text

    /// The message this one replies to, a smaller copy of the full chat's quote.
    private func replyQuote(_ replied: RepliedMessage) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(chatAccent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(replied.senderName)
                    .scaledFont(12, .semibold)
                    .foregroundColor(Color(white: 0.15))
                    .lineLimit(1)
                Text(replied.isDeleted ? bundle.loc("Message unsent") : (replied.content ?? ""))
                    .scaledFont(12)
                    .italic(replied.isDeleted)
                    .foregroundColor(Color(white: 0.32))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: width * 0.8, alignment: .leading)
        // Light grey with dark text in both modes, like the full chat's quote.
        .background(Color(white: 0.91), in: RoundedRectangle(cornerRadius: 10))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func textBubble(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .scaledFont(13)
            .italic(muted)
            .foregroundColor(isOwn && !muted ? .white : AppColors.textPrimary(colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isOwn && !muted ? chatAccent.opacity(0.9) : AppColors.elevated(colorScheme),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: width * 0.85, alignment: isOwn ? .trailing : .leading)
    }
}

/// A video in the floating window: plays, with sound, while it's the one in
/// view in the chat on screen, and only one plays at a time
/// (`FloatingChatPresenter.playingMediaID`). Scrolling it away, switching
/// chat or stashing the window pauses it. Tap to pause or play again.
struct FloatingChatVideo: View {
    @Environment(\.appBundle) private var bundle

    let id: String
    let url: URL
    let bubble: FloatingBubbleState
    let presenter: FloatingChatPresenter
    let width: CGFloat

    @State private var player: AVPlayer?
    @State private var isVisible = false
    @State private var ended = false

    private var isPlaying: Bool { presenter.playingMediaID == id }
    /// Only the chat on screen, with the window out, may play.
    private var canPlay: Bool {
        presenter.active?.id == bubble.id && !presenter.isStashed && !presenter.isHiddenByFullChat
    }

    var body: some View {
        ZStack {
            Color.black
            if let player { FloatingPlayerLayer(player: player) }
            if !isPlaying {
                Image(systemName: ended ? "arrow.counterclockwise.circle.fill" : "play.circle.fill")
                    .scaledFont(34)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: width, height: width * 1.25)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if isPlaying { presenter.playingMediaID = nil } else { claim(restart: ended) }
        }
        .onScrollVisibilityChange(threshold: 0.6) { visible in
            isVisible = visible
            if visible { claim(restart: false) } else if isPlaying { presenter.playingMediaID = nil }
        }
        // Coming back to this chat, or out of the edge, with the video in view.
        .onChange(of: canPlay) { _, can in
            if can, isVisible { claim(restart: false) }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { player?.play() } else { player?.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard (note.object as? AVPlayerItem) === player?.currentItem else { return }
            ended = true
            if isPlaying { presenter.playingMediaID = nil }
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel(Text(bundle.loc("Video")))
    }

    private func claim(restart: Bool) {
        guard canPlay, !(ended && !restart) else { return }
        if player == nil { player = AVPlayer(url: url) }
        if restart {
            player?.seek(to: .zero)
            ended = false
        }
        presenter.playingMediaID = id
        player?.play()
    }
}

/// An `AVPlayerLayer` without controls. The floating window is too small
/// for a scrubber; tapping pauses and plays.
private struct FloatingPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
