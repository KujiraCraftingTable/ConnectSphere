import SwiftUI

/// Inline section shown inside CreatePostView when post type = Event.
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
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Location
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("Location"))
                    .scaledFont(12, .medium)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                LocationSearchField(bundle.loc("Optional"), text: $location) { field in
                    fieldBox(field
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme)))
                }
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
            .scaledFont(14)
            .foregroundColor(AppColors.textPrimary(colorScheme))

            // Optional end time
            Toggle(isOn: $showEndDate) {
                Label(bundle.loc("Add end time"), systemImage: "clock.badge.checkmark")
                    .scaledFont(14)
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
                .scaledFont(14)
                .onAppear { if endsAt == nil { endsAt = startsAt.addingTimeInterval(3600) } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.surface(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                )
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(13, .semibold)
            .foregroundColor(AppColors.textSecondary(colorScheme))
    }

    private func fieldRow<F: View>(label: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            fieldBox(field())
        }
    }

    private func fieldBox<F: View>(_ field: F) -> some View {
        field
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppColors.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
