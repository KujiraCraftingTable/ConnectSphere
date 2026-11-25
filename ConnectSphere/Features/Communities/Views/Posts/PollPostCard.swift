import SwiftUI

/// Card body for poll-type posts. Works like a chat poll (`ChatPollCard`):
/// one vote each, which can be moved or taken back until the poll ends,
/// but shows each option's percentage rather than who picked it.
struct PollPostCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State var vm: PollViewModel

    /// Accent color from the community cover
    var accentColor: Color

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(vm.pollData.options) { option in
                optionRow(option)
            }

            // Footer: total votes, then when it ends (or that it has) and
            // what a tap does. The same footer as a chat poll.
            Text(footerText)
                .scaledFont(12)
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            if let err = vm.errorMessage {
                Text(err)
                    .scaledFont(12)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var footerText: String {
        var parts = [String(format: bundle.loc(vm.pollData.totalVotes == 1 ? "%d vote" : "%d votes"),
                            vm.pollData.totalVotes)]
        if vm.hasEnded {
            parts.append(bundle.loc("Ended"))
        } else {
            if let endsAt = vm.endsAt {
                parts.append(String(format: bundle.loc("Ends %@"), endsAt.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Option rows
    /// One option as in chat polls: a bar sized by its share, your choice
    /// ticked, and, instead of the voters' faces, its percentage. Tapping
    /// votes, moves your vote here, or on your choice takes it back.
    private func optionRow(_ option: PollOption) -> some View {
        let isSelected = vm.pollData.userVote == option.id
        let pct        = vm.percentage(for: option)

        return Button {
            Task { await vm.tap(optionId: option.id) }
        } label: {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(13)
                        .foregroundColor(accentColor)
                }
                Text(option.text)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(isSelected ? accentColor : AppColors.textSecondary(colorScheme))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accentColor.opacity(isSelected ? 0.28 : 0.14))
                        .frame(width: geo.size.width * pct / 100)
                }
            }
            .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.isVoting || vm.hasEnded)
        .animation(.snappy, value: vm.pollData.userVote)
    }
}
