import SwiftUI

/// The card for a `.meeting` message: calendar icon, title, formatted date,
/// optional location, then, in a group, a Going / Maybe / Can't go strip
/// with the going count, or, in a 1:1, the reminder. The proposer gets a
/// menu to reschedule or cancel where the host passes both actions.
/// Cancelled proposals render muted and struck through with RSVP disabled.
///
/// Shared by the full chat (`MessageBubble`) and the floating window, which
/// uses the `compact` style and leaves rescheduling and cancelling to the
/// full chat.
struct MeetingProposalCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @State private var browserURL: URL?

    let proposal: MeetingProposal
    let isOwn: Bool
    let isGroup: Bool
    let currentUserId: String
    let accent: Color
    var isPlayful = false
    /// The floating window's style: smaller type, RSVP buttons wrapping.
    var compact = false
    var onRespond: ((MeetingRsvpStatus) -> Void)? = nil
    var onReschedule: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        let cancelled = proposal.isCancelled
        let iconColor = cancelled ? AppColors.textTertiary(colorScheme) : accent
        let iconSize: CGFloat = compact ? 26 : (isPlayful ? 32 : 36)

        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(alignment: .top, spacing: compact ? 8 : 10) {
                Image(systemName: "calendar")
                    .font(.system(size: compact ? 13 : 16, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: iconSize, height: iconSize)
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
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .strikethrough(cancelled)
                        .foregroundColor(cancelled ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    Text(Self.formattedDate(proposal.startsAt))
                        .font(.system(size: compact ? 11 : 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(compact ? 2 : 1)
                }

                Spacer(minLength: 4)

                if isOwn && !cancelled, let onReschedule, let onCancel {
                    Menu {
                        Button(action: onReschedule) {
                            Label(bundle.loc("Reschedule"), systemImage: "pencil")
                        }
                        Button(role: .destructive, action: onCancel) {
                            Label(bundle.loc("Cancel meeting"), systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .scaledFont(13, .semibold)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .padding(6)
                    }
                }
            }

            if let location = proposal.location, !location.isEmpty {
                Button {
                    openLocation(location)
                } label: {
                    Label(location, systemImage: "mappin.circle")
                        .font(.system(size: compact ? 11 : 13))
                        .foregroundColor(accent)
                        .lineLimit(compact ? 2 : nil)
                }
                .buttonStyle(.plain)
            }

            if cancelled {
                Text("Cancelled", bundle: bundle)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundColor(.red)
            } else if isGroup {
                // Groups keep RSVP. A 1:1 pair already coordinates by
                // talking, so RSVP would be redundant there (see the
                // reminder row below). The count has its own line: sharing the
                // buttons' row crowded and wrapped them.
                VStack(alignment: .leading, spacing: 6) {
                    FlowLayout(spacing: compact ? 5 : 8) {
                        ForEach([MeetingRsvpStatus.going, .maybe, .notGoing], id: \.self) { status in
                            rsvpButton(status)
                        }
                    }
                    Text(String(format: bundle.loc("%d going"), proposal.count(for: .going)))
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            } else {
                reminderRow
            }
        }
        .padding(compact ? 9 : (isPlayful ? 12 : 14))
        .frame(maxWidth: compact ? .infinity : 300, alignment: .leading)
        // The post-card white, so the card stands off the chat background.
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: compact ? 12 : 14))
        .overlay {
            if !isPlayful {
                RoundedRectangle(cornerRadius: compact ? 12 : 14).stroke(accent.opacity(0.18), lineWidth: 1)
            }
        }
        .opacity(cancelled ? 0.65 : 1)
        .inAppBrowser(url: $browserURL)
    }

    /// Non-interactive reminder indicator shown in place of RSVP buttons for
    /// a 1:1 proposal (RSVP is redundant there. The two people already
    /// coordinate by talking; the reminder is what actually matters).
    private var reminderRow: some View {
        let offset = proposal.reminderOffsetValue ?? .oneDayBefore
        return HStack(spacing: 6) {
            Image(systemName: offset.icon)
                .font(.system(size: compact ? 11 : 12))
            Text(String(format: bundle.loc("Reminder: %@"), bundle.loc(offset.label)))
                .font(.system(size: compact ? 11 : 12))
                .lineLimit(compact ? 2 : 1)
        }
        .foregroundColor(AppColors.textTertiary(colorScheme))
    }

    private func rsvpButton(_ status: MeetingRsvpStatus) -> some View {
        let isActive = proposal.myResponse(userId: currentUserId) == status
        return Button {
            onRespond?(status)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: compact ? 10 : 12))
                rsvpLabel(status)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(isActive ? accent : AppColors.base(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onRespond == nil)
    }

    private func rsvpLabel(_ status: MeetingRsvpStatus) -> Text {
        switch status {
        case .going:    return Text("Going", bundle: bundle)
        case .maybe:    return Text("Maybe", bundle: bundle)
        case .notGoing: return Text("Can't go", bundle: bundle)
        }
    }

    /// Short formatted date: "Sat, Jun 7 · 7:00 PM", same format as EventPostCard.
    static func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        return "\(df.string(from: date)) · \(tf.string(from: date))"
    }

    /// Opens the proposal's location on Google Maps in the in-app browser first;
    /// "Open app" there continues in the Maps app.
    private func openLocation(_ location: String) {
        // `.urlQueryAllowed` leaves RFC 3986 sub-delims (&, +, =, ;, ,) unescaped,
        // fine for a full query STRING, wrong for a single query VALUE embedded
        // inside one (e.g. "H&M Cafe" would truncate the query at the `&`).
        // Excluding them here forces they get percent-encoded too.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=;,")
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        browserURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)")
    }
}
