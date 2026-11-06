import SwiftUI

/// Card body for event-type posts. Shows event details and 3-button RSVP strip.
struct EventPostCard: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State var vm: EventViewModel

    var accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Event header row
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(accentColor)
                    .frame(width: 32, height: 32)
                    .background(accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.eventData.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))

                    Text(formattedDate)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
            }

            // Location (if present)
            if let location = vm.eventData.location, !location.isEmpty {
                Label(location, systemImage: "mappin.circle")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            // RSVP strip
            HStack(spacing: 8) {
                ForEach([RsvpStatus.going, .maybe, .notGoing], id: \.self) { status in
                    rsvpButton(status)
                }
                Spacer()
                Text(String(format: bundle.loc("%d going"), vm.eventData.rsvpCount))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }

            if let err = vm.errorMessage {
                Text(err).font(.system(size: 12)).foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func rsvpButton(_ status: RsvpStatus) -> some View {
        let isActive = vm.eventData.userRsvp == status
        return Button {
            Task<Void, Never>(name: nil) { await vm.rsvp(status: status) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .font(.system(size: 12))
                Text(bundle.loc(status.label))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isActive ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? accentColor : AppColors.elevated(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isUpdating)
    }

    /// Short formatted date: "Sat, Jun 7 · 7:00 PM" (or the Vietnamese
    /// equivalent), locale-aware so weekday/month names and AM/PM markers
    /// follow the in-app language, same convention as Date+Extensions.timeAgoString.
    private var formattedDate: String {
        let isVi = (UserDefaults.standard.string(forKey: "appLanguage") ?? "vi") == "vi"
        let locale = Locale(identifier: isVi ? "vi_VN" : "en_US")

        let df = DateFormatter()
        df.locale = locale
        df.dateFormat = "EEE, MMM d"
        let tf = DateFormatter()
        tf.locale = locale
        tf.dateFormat = "h:mm a"
        return "\(df.string(from: vm.eventData.startsAt)) · \(tf.string(from: vm.eventData.startsAt))"
    }
}
