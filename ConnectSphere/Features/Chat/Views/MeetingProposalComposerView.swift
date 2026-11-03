import SwiftUI
import Observation

/// Meeting proposal composer used by `ChatView` for both "new proposal" and
/// "reschedule" (`ChatView.meetingComposerSheet`). Forked from Communities'
/// shared `CreateEventSheet` rather than extended — Chat's proposal needs
/// fields event-posts don't (a hard-capped title, MapKit location
/// autocomplete, a mandatory reminder picker) and forking keeps the two
/// unrelated features decoupled. `CreateEventSheet` itself is untouched.
struct MeetingProposalComposerView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle

    @Binding var title: String
    @Binding var location: String
    @Binding var startsAt: Date
    @Binding var endsAt: Date?
    @Binding var showEndDate: Bool
    @Binding var reminderOffset: MeetingReminderOffset

    private let titleLimit = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Meeting Details")

            // Title — hard-capped at 40 characters, actively trimmed rather
            // than just blocking further input.
            fieldRow(label: "Title") {
                TextField(bundle.loc("Meeting title"), text: $title)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .onChange(of: title) { _, newValue in
                        if newValue.count > titleLimit {
                            title = String(newValue.prefix(titleLimit))
                        }
                    }
            }
            Text(String(format: bundle.loc("%d/%d characters"), title.count, titleLimit))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(colorScheme))
                .padding(.top, -6)
                // `.onChange` above only catches edits made WHILE this view is
                // visible — a reschedule pre-fills `title` from the existing
                // proposal before this view appears, which never fires
                // `.onChange`. Normalize once on appear so a pre-existing
                // title over the limit (e.g. from a legacy client) is also
                // trimmed, not just newly-typed text.
                .task {
                    if title.count > titleLimit {
                        title = String(title.prefix(titleLimit))
                    }
                }

            // Location — MapKit suggestions under the field; tapping one fills it.
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("Location"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                LocationSearchField(bundle.loc("Search for a location"), text: $location) { field in
                    fieldBox(field
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary(colorScheme)))
                }
            }

            Divider()

            // Start date/time
            DatePicker(
                bundle.loc("Starts at"),
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

            Divider()

            // Reminder — mandatory, defaults to "1 day before" (no "None" option).
            // Menu style rather than segmented: the 4 labels ("2 days before",
            // "1 week before", …) are too long to fit legibly side-by-side in
            // a composer this narrow.
            HStack {
                sectionLabel("Reminder")
                Spacer()
                Picker(bundle.loc("Reminder"), selection: $reminderOffset) {
                    ForEach(MeetingReminderOffset.allCases, id: \.self) { option in
                        Label(bundle.loc(option.label), systemImage: option.icon).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppColors.textPrimary(colorScheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.surface(colorScheme))
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(bundle.loc(key))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppColors.textSecondary(colorScheme))
    }

    private func fieldRow<F: View>(label: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bundle.loc(label))
                .font(.system(size: 12, weight: .medium))
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
