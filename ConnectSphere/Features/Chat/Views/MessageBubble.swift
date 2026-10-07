import SwiftUI
import AVFoundation

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool
    let palette: ThemePalette
    /// Needed to derive "my RSVP" from a meeting proposal's status→user-ids map
    /// (same convention as `Message.myReaction(userId:)`).
    var currentUserId: String = ""
    /// Every other participant in this conversation (excludes the current
    /// user) — a 1:1 chat has exactly one id here, a group has N. Drives
    /// `statusIcon`'s delivered/read rendering; threaded in the same way
    /// `currentUserId` is (parent computes it once from `ChatViewModel`).
    var otherParticipantIds: [String] = []
    /// The conversation's canonical group/1:1 flag (`ChatViewModel.isGroup`,
    /// mirrors the server's `conversations.is_group`) — NOT derived from
    /// `otherParticipantIds.count`, since a group can have as few as 1 other
    /// member (nothing enforces a minimum), which would make that heuristic
    /// disagree with the server. Drives meeting-proposal RSVP-vs-reminder
    /// gating, where the mismatch previously meant a 2-person group's meeting
    /// could never be RSVP'd to (and its reminder could never fire) since the
    /// UI rendered the 1:1 reminder-only row while the server still expected
    /// RSVPs. The read-receipts glyph below still keys off participant count
    /// on purpose — that's cosmetic (which glyph), not a lost feature.
    var isGroup: Bool = false
    /// Hobby mode = rounder bubble + bigger reaction pills; Work mode = crisper
    /// bubble + today's tighter reaction-pill sizing. Threaded in from ChatView
    /// (`appState.currentMode == .hobby`), same convention as `palette`.
    var isPlayful: Bool = false
    /// Whether this bubble shows its time + read receipt. `ChatView` turns it
    /// off for all but the last message in a same-sender run
    /// (`ChatTimeline.endsRun`), so a burst of messages carries one time
    /// instead of a stamp on every line.
    var showsMeta: Bool = true
    /// Tapping the image/video in the bubble — the parent opens the fullscreen viewer
    var onMediaTap: ((Message) -> Void)? = nil
    /// Tapping the quoted preview — the parent jumps to the original message (jump-to-message)
    var onReplyPreviewTap: ((String) -> Void)? = nil
    /// RSVP tapped on a meeting proposal card
    var onMeetingRespond: ((Message, MeetingRsvpStatus) -> Void)? = nil
    /// "Reschedule" chosen from the proposer's menu — parent opens the composer pre-filled
    var onMeetingEdit: ((Message) -> Void)? = nil
    /// "Cancel meeting" confirmed from the proposer's menu
    var onMeetingCancel: ((Message) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.openURL) private var openURL
    @State private var showCancelConfirm = false
    // Voice playback state, scoped to this one bubble — one AVAudioPlayer
    // instance per bubble is fine since voice messages are typically short.
    @State private var voicePlayer: AVAudioPlayer?
    @State private var voiceIsPlaying = false
    @State private var voicePlaybackProgress: Double = 0
    @State private var voiceProgressTimer: Timer?

    private var bubbleShape: BubbleShape { BubbleShape(isOwn: isOwn, isPlayful: isPlayful) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isOwn { Spacer(minLength: 60) }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
                if let replyToId = message.replyToMessageId, let replied = message.repliedMessage {
                    replyPreview(replied, replyToId: replyToId)
                }
                bubbleContent
                if !message.reactions.isEmpty {
                    reactionRow
                }
                if showsMeta {
                    metaRow
                }
            }

            if !isOwn { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .confirmationDialog(
            Text("Cancel meeting proposal?", bundle: bundle),
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                onMeetingCancel?(message)
            } label: {
                Text("Cancel meeting", bundle: bundle)
            }
            Button(role: .cancel) {
            } label: {
                Text("Keep it", bundle: bundle)
            }
        }
    }

    // MARK: - Quoted reply preview

    /// Compact quoted block above the bubble content — tap jumps to the original message.
    ///
    /// It sits on the chat background, not inside the colored bubble, so it
    /// is a fixed light-grey chip with dark text in both light and dark mode.
    /// Colors that assumed the blue bubble behind it (white text on a 15%
    /// white wash) made it all but invisible on a light background.
    private func replyPreview(_ replied: RepliedMessage, replyToId: String) -> some View {
        Button {
            onReplyPreviewTap?(replyToId)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.primary)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(replied.senderName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Self.replyChipName)
                        .lineLimit(1)
                    Text(replied.isDeleted ? bundle.loc("Message unsent") : (replied.content ?? ""))
                        .font(.system(size: 13))
                        .italic(replied.isDeleted)
                        .foregroundColor(Self.replyChipText)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Self.replyChipBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Deliberately not theme-adaptive: the chip stays light grey with dark
    // text in both modes, so the quote stands out on any chat background.
    private static let replyChipBackground = Color(white: 0.91)
    private static let replyChipName = Color(white: 0.15)
    private static let replyChipText = Color(white: 0.32)

    // MARK: - Reaction pills

    /// Small pill row below the bubble summarising reactions (emoji + count).
    /// The current user's own reaction (if any) is highlighted in the palette
    /// color so it reads distinctly from everyone else's.
    private var reactionRow: some View {
        let mine = message.myReaction(userId: currentUserId)
        return HStack(spacing: 4) {
            ForEach(message.reactionSummary, id: \.emoji) { item in
                let isMine = item.emoji == mine
                HStack(spacing: 2) {
                    Text(item.emoji).font(.system(size: isPlayful ? 13 : 11))
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isMine ? .white : AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(.horizontal, isPlayful ? 7 : 6)
                .padding(.vertical, isPlayful ? 4 : 3)
                .background(isMine ? AnyShapeStyle(palette.primary) : AnyShapeStyle(AppColors.elevated(colorScheme)), in: Capsule())
            }
        }
    }

    // MARK: - Bubble content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isDeleted {
            // Placeholder for a recalled message
            Text("Message unsent", bundle: bundle)
                .font(.system(size: 14))
                .italic()
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.elevated(colorScheme))
                .clipShape(bubbleShape)
        } else {
            normalBubbleContent
        }
    }

    @ViewBuilder
    private var normalBubbleContent: some View {
        switch message.messageType {
        case .text, .unknown:
            if let text = message.content {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(bubbleShape)
            }

        case .image:
            if let url = message.absoluteMediaURL() {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(bubbleShape)
                            .contentShape(bubbleShape)
                            .onTapGesture { onMediaTap?(message) }
                    case .failure:
                        imagePlaceholder(icon: "photo", label: bundle.loc("Photo"))
                    default:
                        ProgressView()
                            .frame(width: 180, height: 140)
                            .background(AppColors.elevated(colorScheme))
                            .clipShape(bubbleShape)
                    }
                }
            }

        case .album:
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                AlbumStackBubble(urls: message.albumURLs(), isOwn: isOwn) { onMediaTap?(message) }
                if let caption = message.content, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 15))
                        .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                }
            }

        case .video:
            videoBubble

        case .voice:
            voiceBubble

        case .meeting:
            if let proposal = message.meetingProposal {
                meetingProposalCard(proposal)
            }
        }
    }

    // MARK: - Meeting proposal card

    /// Card shown for `.meeting` messages: calendar icon, title, formatted date,
    /// optional location, a 3-button RSVP strip (going count), and — for the
    /// proposer only — a menu to reschedule/cancel. Cancelled proposals render
    /// muted/struck-through with RSVP disabled.
    private func meetingProposalCard(_ proposal: MeetingProposal) -> some View {
        let cancelled = proposal.isCancelled
        let iconColor = cancelled ? AppColors.textTertiary(colorScheme) : palette.primary

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: isPlayful ? 32 : 36, height: isPlayful ? 32 : 36)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        // Work mode gives the meeting card a bit more visual
                        // weight, since scheduling is a work-relevant action.
                        if !isPlayful {
                            RoundedRectangle(cornerRadius: 8).stroke(iconColor.opacity(0.35), lineWidth: 1)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 15, weight: .semibold))
                        .strikethrough(cancelled)
                        .foregroundColor(cancelled ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    Text(formattedMeetingDate(proposal.startsAt))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isOwn && !cancelled {
                    Menu {
                        Button {
                            onMeetingEdit?(message)
                        } label: {
                            Label(bundle.loc("Reschedule"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showCancelConfirm = true
                        } label: {
                            Label(bundle.loc("Cancel meeting"), systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(6)
                    }
                }
            }

            if let location = proposal.location, !location.isEmpty {
                Button {
                    openMeetingLocation(location)
                } label: {
                    Label(location, systemImage: "mappin.circle")
                        .font(.system(size: 13))
                        .foregroundColor(palette.primary)
                }
                .buttonStyle(.plain)
            }

            if cancelled {
                Text("Cancelled", bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
            } else if isGroup {
                // Groups keep RSVP — a 1:1 pair already coordinates by
                // talking, so RSVP would be redundant there (see the
                // reminder-indicator branch below). Count moved onto its own
                // line (was sharing the buttons' HStack, which is what
                // caused the crowding/wrap bug).
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach([MeetingRsvpStatus.going, .maybe, .notGoing], id: \.self) { status in
                            meetingRsvpButton(status, proposal: proposal)
                        }
                    }
                    Text(String(format: bundle.loc("%d going"), proposal.count(for: .going)))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            } else {
                meetingReminderRow(proposal)
            }
        }
        .padding(isPlayful ? 12 : 14)
        .frame(maxWidth: 300, alignment: .leading)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if !isPlayful {
                RoundedRectangle(cornerRadius: 14).stroke(palette.primary.opacity(0.18), lineWidth: 1)
            }
        }
        .opacity(cancelled ? 0.65 : 1)
    }

    /// Non-interactive reminder indicator shown in place of RSVP buttons for
    /// a 1:1 proposal (RSVP is redundant there — the two people already
    /// coordinate by talking; the reminder is what actually matters).
    private func meetingReminderRow(_ proposal: MeetingProposal) -> some View {
        let offset = proposal.reminderOffsetValue ?? .oneDayBefore
        return HStack(spacing: 6) {
            Image(systemName: offset.icon)
                .font(.system(size: 12))
            Text(String(format: bundle.loc("Reminder: %@"), bundle.loc(offset.label)))
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundColor(AppColors.textTertiary(colorScheme))
    }

    /// Opens the proposal's location in Google Maps — the native app if
    /// installed (probed via `canOpenURL`, which requires `comgooglemaps`
    /// whitelisted in `LSApplicationQueriesSchemes`), else the web fallback
    /// in the default browser (always works, no whitelisting needed).
    private func openMeetingLocation(_ location: String) {
        // `.urlQueryAllowed` leaves RFC 3986 sub-delims (&, +, =, ;, ,) unescaped —
        // fine for a full query STRING, wrong for a single query VALUE embedded
        // inside one (e.g. "H&M Cafe" would truncate the query at the `&`).
        // Excluding them here forces they get percent-encoded too.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=;,")
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        if let appURL = URL(string: "comgooglemaps://?q=\(encoded)"), UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else if let webURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)") {
            openURL(webURL)
        }
    }

    private func meetingRsvpButton(_ status: MeetingRsvpStatus, proposal: MeetingProposal) -> some View {
        let isActive = proposal.myResponse(userId: currentUserId) == status
        return Button {
            onMeetingRespond?(message, status)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 12))
                meetingRsvpLabel(status)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? palette.primary : AppColors.base(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func meetingRsvpLabel(_ status: MeetingRsvpStatus) -> Text {
        switch status {
        case .going:    return Text("Going", bundle: bundle)
        case .maybe:    return Text("Maybe", bundle: bundle)
        case .notGoing: return Text("Can't go", bundle: bundle)
        }
    }

    /// Short formatted date: "Sat, Jun 7 · 7:00 PM" — same format as EventPostCard.
    private func formattedMeetingDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        return "\(df.string(from: date)) · \(tf.string(from: date))"
    }

    /// Video bubble: dark background + play button, tapping opens the fullscreen viewer
    /// (video doesn't play inline in the list).
    private var videoBubble: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.92))
        }
        .frame(width: 200, height: 140)
        .clipShape(bubbleShape)
        .contentShape(bubbleShape)
        .onTapGesture { onMediaTap?(message) }
    }

    // MARK: - Voice message bubble

    /// Number of waveform bars rendered — matches the fixed ~40-point sample
    /// count `VoiceRecorderControl` captures client-side at record time.
    private static let voiceWaveformBarCount = 40

    /// Play/pause button + waveform + duration label, backed by a local
    /// `AVAudioPlayer`. The waveform's bar heights come straight from
    /// `message.voiceWaveform` — deterministic and identical for every
    /// viewer since the samples were captured once client-side at record
    /// time and sent with the message, so no audio re-analysis happens here.
    /// Only the played-vs-unplayed bar color split is driven by local
    /// playback state.
    private var voiceBubble: some View {
        // The duration gets its own line at the bottom right rather than
        // sharing the row: beside a fixed-width waveform it was squeezed to
        // a few points and wrapped one character per line.
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 10) {
                Button {
                    toggleVoicePlayback()
                } label: {
                    Image(systemName: voiceIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(isOwn ? .white : palette.primary)
                }
                .buttonStyle(.plain)

                voiceWaveformView
            }

            Text(voiceDurationLabel)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isOwn ? .white.opacity(0.85) : AppColors.textSecondary(colorScheme))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: 230)
        .background(bubbleBackground)
        .clipShape(bubbleShape)
        .onDisappear { stopVoicePlayback() }
    }

    private var voiceWaveformView: some View {
        // Empty/missing waveform (e.g. a malformed or very old row) renders a
        // flat placeholder row instead of crashing on an empty array index.
        let samples: [Float] = {
            guard let w = message.voiceWaveform, !w.isEmpty else {
                return Array(repeating: Float(0.15), count: Self.voiceWaveformBarCount)
            }
            return w
        }()
        let playedBars = Int(voicePlaybackProgress * Double(samples.count))
        let activeColor = isOwn ? Color.white : palette.primary
        let mutedColor = isOwn ? Color.white.opacity(0.4) : AppColors.textTertiary(colorScheme)

        // Bars are spread across whatever width is left beside the play
        // button, instead of a fixed 40 × (2pt + 2pt gap) that could crowd
        // out its neighbours.
        return Canvas { context, size in
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(1.5, step - 2)
            for (index, sample) in samples.enumerated() {
                let barHeight = max(3, CGFloat(sample) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - barHeight) / 2,
                                  width: barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(index < playedBars ? activeColor : mutedColor))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .accessibilityHidden(true)
    }

    private var voiceDurationLabel: String {
        let seconds = message.voiceDurationSeconds ?? 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggleVoicePlayback() {
        if voiceIsPlaying {
            stopVoicePlayback()
            return
        }
        guard let url = message.absoluteMediaURL() else { return }

        // AVAudioPlayer needs local data/a file URL, so fetch the remote
        // audio into memory first, then decode it on the main thread.
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else { return }
            DispatchQueue.main.async {
                do {
                    let player = try AVAudioPlayer(data: data)
                    player.prepareToPlay()
                    self.voicePlayer = player
                    player.play()
                    self.voiceIsPlaying = true
                    self.startVoiceProgressTimer()
                } catch {
                    self.voiceIsPlaying = false
                }
            }
        }.resume()
    }

    private func startVoiceProgressTimer() {
        voiceProgressTimer?.invalidate()
        voiceProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player = self.voicePlayer else { return }
            if player.isPlaying {
                self.voicePlaybackProgress = player.duration > 0 ? player.currentTime / player.duration : 0
            } else {
                self.stopVoicePlayback()
            }
        }
    }

    private func stopVoicePlayback() {
        voicePlayer?.stop()
        voiceProgressTimer?.invalidate()
        voiceProgressTimer = nil
        voiceIsPlaying = false
        voicePlaybackProgress = 0
    }

    private func imagePlaceholder(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(isOwn ? .white.opacity(0.8) : AppColors.textSecondary(colorScheme))
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isOwn ? .white : AppColors.textPrimary(colorScheme))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(bubbleBackground)
        .clipShape(bubbleShape)
    }

    private var bubbleBackground: some ShapeStyle {
        isOwn
            ? AnyShapeStyle(palette.primary)
            : AnyShapeStyle(AppColors.surface(colorScheme))
    }

    // MARK: - Timestamp + status

    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(message.createdAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))

            if isOwn {
                statusIcon
            }
        }
    }

    /// Derived from `deliveredTo`/`readBy` against `otherParticipantIds` rather
    /// than a single enum. For the 1:1 case (exactly one other participant)
    /// this reproduces the old `sent`/`delivered`/`read` visuals exactly —
    /// single checkmark / hollow double-check / filled colored double-check —
    /// since "the other person" is the entire `otherParticipantIds` set.
    /// Groups (N > 1) instead show a compact "Read n/total" label once at
    /// least one other member has read it, falling back to the same
    /// sent/delivered glyphs otherwise.
    @ViewBuilder
    private var statusIcon: some View {
        let total = otherParticipantIds.count
        let readCount = message.readCount(among: otherParticipantIds)
        let deliveredCount = message.deliveredCount(among: otherParticipantIds)

        if total > 1 {
            groupStatusView(readCount: readCount, total: total)
        } else if readCount > 0 {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.primary)
        } else if deliveredCount > 0 {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }

    /// Group (N > 1 other participants) status: filled colored check once
    /// everyone has read it, a compact "Read n/total" label while some (but
    /// not all) have, otherwise the same sent/delivered glyph the 1:1 case
    /// uses — kept unobtrusive so it doesn't widen the bubble's meta row.
    @ViewBuilder
    private func groupStatusView(readCount: Int, total: Int) -> some View {
        if readCount >= total {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(palette.primary)
        } else if readCount > 0 {
            Text(String(format: bundle.loc("Read %d/%d"), readCount, total))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else if message.deliveredCount(among: otherParticipantIds) > 0 {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
    }
}

// MARK: - Bubble Shape

private struct BubbleShape: Shape {
    let isOwn: Bool
    /// Hobby mode gets a rounder, softer bubble; Work mode a crisper one.
    /// Baseline (both modes before this) was r=18/tail=4.
    var isPlayful: Bool = false
    private var r: CGFloat { isPlayful ? 20 : 15 }
    private var tail: CGFloat { isPlayful ? 6 : 3 }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)

        if isOwn {
            path.move(to: CGPoint(x: minX + r, y: minY))
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - r - tail))
            path.addQuadCurve(to: CGPoint(x: maxX - tail, y: maxY), control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addQuadCurve(to: CGPoint(x: minX, y: maxY - r), control: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        } else {
            path.move(to: CGPoint(x: minX + r, y: minY))
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY - r))
            path.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + tail, y: maxY))
            path.addQuadCurve(to: CGPoint(x: minX, y: maxY - tail), control: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Typing indicator dots

struct TypingIndicatorBubble: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppColors.textTertiary(colorScheme))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == i ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.surface(colorScheme))
        .clipShape(BubbleShape(isOwn: false))
        .padding(.leading, 12)
        .onAppear { phase = 0 }
    }
}
