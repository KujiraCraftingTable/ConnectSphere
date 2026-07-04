import SwiftUI

/// Card body for poll-type posts. Shows options with progress bars and voting UI.
struct PollPostCard: View {
    @Environment(\.colorScheme) var colorScheme
    @State var vm: PollViewModel

    /// Accent color from the community cover
    var accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(vm.pollData.options) { option in
                optionRow(option)
            }

            // Footer: total votes + optional end date
            HStack {
                Text("\(vm.pollData.totalVotes) vote\(vm.pollData.totalVotes == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Spacer()
                if let endsAt = vm.pollData.options.first?.endsAt {
                    Text("Ends \(endsAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }
            .padding(.top, 4)

            if let err = vm.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func optionRow(_ option: PollOption) -> some View {
        let hasVoted   = vm.pollData.userVote != nil
        let isSelected = vm.pollData.userVote == option.id
        let pct        = vm.percentage(for: option)

        Button {
            guard !hasVoted else { return }
            Task<Void, Never>(name: nil) { await vm.vote(optionId: option.id) }
        } label: {
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.elevated(colorScheme))
                    .frame(height: 38)

                // Progress fill
                if hasVoted {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected
                                  ? accentColor.opacity(0.25)
                                  : accentColor.opacity(0.08))
                            .frame(width: geo.size.width * pct / 100, height: 38)
                    }
                    .frame(height: 38)
                }

                // Label row
                HStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(accentColor)
                    }
                    Text(option.text)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Spacer()
                    if hasVoted {
                        Text(String(format: "%.0f%%", pct))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isSelected ? accentColor : AppColors.textSecondary(colorScheme))
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .buttonStyle(.plain)
        .disabled(hasVoted || vm.isVoting)
    }
}
