import SwiftUI

/// Inline section shown inside CommunityCreatePostView when post type = Event.
/// Captures title, optional location, starts_at, and optional ends_at.
struct CreateEventSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var title: String
    @Binding var location: String
    @Binding var startsAt: Date
    @Binding var endsAt: Date?
    @Binding var showEndDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Event Details")

            // Title
            fieldRow(label: "Title *") {
                TextField("Event title", text: $title)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Location
            fieldRow(label: "Location") {
                TextField("Optional", text: $location)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            Divider()

            // Start date/time
            DatePicker(
                "Starts at *",
                selection: $startsAt,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(.system(size: 14))
            .foregroundColor(AppColors.textPrimary(colorScheme))

            // Optional end time
            Toggle(isOn: $showEndDate) {
                Label("Add end time", systemImage: "clock.badge.checkmark")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(.purple)

            if showEndDate {
                DatePicker(
                    "Ends at",
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
