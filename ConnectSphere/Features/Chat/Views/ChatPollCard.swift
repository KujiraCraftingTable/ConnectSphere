import SwiftUI

/// A group poll in a chat: the question, then each option as a bar sized by
/// its share of the votes, with its count and the faces of who picked it
/// (tap the faces for the names). Your own choice is ticked. While the poll
/// is open, tapping an option votes for it or moves your vote there, and
/// tapping your ticked choice takes the vote back.
///
/// Shared by the full chat (`MessageBubble`) and the floating window
/// (`compact`).
struct ChatPollCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let question: String
    let poll: ChatPoll
    let currentUserId: String
    let accent: Color
    var compact = false
    var onVote: ((String) -> Void)? = nil

    @State private var votersFor: ChatPoll.Option?

    private var myOption: String? { poll.myOptionID(userId: currentUserId) }
    private var canVote: Bool { !poll.hasEnded() && onVote != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: compact ? 11 : 13))
                    .foregroundColor(accent)
                    .padding(.top, 2)
                Text(question)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(poll.options) { option in
                optionRow(option)
            }
            footer
        }
        .padding(compact ? 9 : 12)
        .frame(maxWidth: compact ? .infinity : 300, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: compact ? 12 : 14))
        .sheet(item: $votersFor) { option in
            PollVotersSheet(option: option)
        }
    }

    private func optionRow(_ option: ChatPoll.Option) -> some View {
        let mine = myOption == option.id
        let share = poll.share(of: option)
        return HStack(spacing: 6) {
            Button { onVote?(option.id) } label: {
                HStack(spacing: 5) {
                    if mine {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: compact ? 11 : 13))
                            .foregroundColor(accent)
                    }
                    Text(option.text)
                        .font(.system(size: compact ? 12 : 14, weight: mine ? .semibold : .regular))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text("\(option.voteCount)")
                        .font(.system(size: compact ? 11 : 12, weight: .medium).monospacedDigit())
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, compact ? 5 : 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(mine ? 0.28 : 0.14))
                            .frame(width: geo.size.width * share)
                    }
                }
                .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canVote)
            .accessibilityValue(Text(String(format: bundle.loc("%lld votes"), option.voteCount)))

            if !option.voters.isEmpty {
                voterFaces(option)
            }
        }
    }

    /// Up to three overlapping faces and "+n"; tap for everyone's names.
    private func voterFaces(_ option: ChatPoll.Option) -> some View {
        let size: CGFloat = compact ? 16 : 20
        let shown = option.voters.prefix(3)
        return HStack(spacing: -size * 0.35) {
            ForEach(Array(shown)) { voter in
                Avatar(name: voter.displayName, colorHex: voter.avatarColor ?? AppColors.avatarFallback,
                       imageURL: voter.avatarUrl, diameter: size)
                    .overlay(Circle().stroke(AppColors.surface(colorScheme), lineWidth: 1.5))
            }
            if option.voters.count > shown.count {
                Text("+\(option.voters.count - shown.count)")
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.leading, size * 0.45)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { votersFor = option }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(String(format: bundle.loc("Who voted for %@"), option.text)))
    }

    private var footer: some View {
        var parts = [poll.totalVotes == 1 ? bundle.loc("1 vote") : String(format: bundle.loc("%lld votes"), poll.totalVotes)]
        if poll.hasEnded() {
            parts.append(bundle.loc("Ended"))
        } else if let end = poll.endsAt {
            parts.append(String(format: bundle.loc("Ends %@"), MeetingProposalCard.formattedDate(end)))
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: compact ? 10 : 12))
            .foregroundColor(AppColors.textTertiary(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Everyone who picked one option, in the order they voted.
private struct PollVotersSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle

    let option: ChatPoll.Option

    var body: some View {
        NavigationStack {
            List(option.voters) { voter in
                HStack(spacing: 12) {
                    Avatar(name: voter.displayName, colorHex: voter.avatarColor ?? AppColors.avatarFallback,
                           imageURL: voter.avatarUrl, diameter: 36)
                    Text(voter.displayName)
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
            }
            .navigationTitle(option.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A new poll for a group chat: the question, then 2–6 options and an
/// optional end date (the same editor post polls use).
struct ChatPollComposer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    /// Sends the poll; returns whether it went, so the sheet only closes then.
    let onSend: (_ question: String, _ options: [String], _ endsAt: Date?) async -> Bool

    @State private var question = ""
    @State private var options = ["", ""]
    @State private var endsAt: Date?
    @State private var showEndDate = false
    @State private var isSending = false
    /// A question, an option, or an end date entered. Closing would lose it.
    private var hasInput: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty
            || options.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } || endsAt != nil
    }

    private var cleanedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The server's rules (ChatStore.validatePoll), so Send is only offered
    /// for a poll that will go through.
    private var canSend: Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = cleanedOptions
        return !q.isEmpty && q.count <= 200 && (2...6).contains(opts.count)
            && opts.allSatisfy { $0.count <= 80 }
            && Set(opts.map { $0.lowercased() }).count == opts.count
            && !isSending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(bundle.loc("Ask a question"), text: $question, axis: .vertical)
                        .scaledFont(16, .semibold)
                        .lineLimit(1...4)
                        .padding(12)
                        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                    CreatePollSheet(options: $options, endsAt: $endsAt, showEndDate: $showEndDate)
                }
                .padding(16)
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("New poll"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasInput)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: hasInput) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Send")) { send() }
                        .disabled(!canSend)
                }
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            let sent = await onSend(question.trimmingCharacters(in: .whitespacesAndNewlines), cleanedOptions,
                                    showEndDate ? endsAt : nil)
            isSending = false
            if sent { dismiss() }
        }
    }
}
