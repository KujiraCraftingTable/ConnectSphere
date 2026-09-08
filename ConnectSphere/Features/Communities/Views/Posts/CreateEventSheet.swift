import SwiftUI

/// Inline section shown inside CommunityCreatePostView when post type = Event.
/// Captures title, optional location, starts_at, and optional ends_at.
struct CreateEventSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Binding var title: String
    @Binding var location: String
    @Binding var startsAt: Date
    @Binding var endsAt: Date?
    @Binding var showEndDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(bundle.loc("Event Details"))

            // Title
            fieldRow(label: bundle.loc("Title") + " *") {
                TextField(bundle.loc("Event title"), text: $title)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Location
            fieldRow(label: bundle.loc("Location")) {
                TextField(bundle.loc("Optional"), text: $location)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            Divider()

            // Start date/time
            DatePicker(
                bundle.loc("Starts at") + " *",
                selection: $startsAt,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(.system(size: 14))
            .foregroundColor(AppColors.textPrimary(colorScheme))

            // Optional end time
            Toggle(isOn: $showEndDate) {
                Label(bundle.loc("Add end time"), systemImage: "clock.badge.checkmark")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(themeManager.theme.primary)

            if showEndDate {
                DatePicker(
                    bundle.loc("Ends at"),
                    selection: Binding(
                        get:  { endsAt ?? startsAt.addingTimeInterval(3600) },
                        set:  { endsAt = $0 }
                    ),
                    in: startsAt...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .font(.system(size: 14))
                .onAppear { if endsAt == nil { endsAt = startsAt.addingTimeInterval(3600) } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.surface(colorScheme))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppColors.textSecondary(colorScheme))
    }

    private func fieldRow<F: View>(label: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            field()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppColors.elevated(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
