import SwiftUI
import MapKit
import Observation

/// Thin `MKLocalSearchCompleter` wrapper feeding the location-autocomplete
/// list below `MeetingProposalComposerView`'s location field. Text-based
/// place/address search only (no "near me" / current-location search), which
/// per Apple's `MKLocalSearchCompleter` docs needs no `CLLocationManager`
/// authorization and no `Info.plist` usage-description key — confirmed
/// during Phase 3 investigation, so none was added.
@Observable
final class LocationSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter = {
        let c = MKLocalSearchCompleter()
        c.resultTypes = [.address, .pointOfInterest]
        return c
    }()

    override init() {
        super.init()
        completer.delegate = self
    }

    /// Updates the search query — matching results arrive asynchronously via
    /// `completerDidUpdateResults`. Clears immediately for an empty/whitespace
    /// fragment rather than waiting on the completer.
    func search(_ fragment: String) {
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = fragment
    }

    /// Clears the results list (e.g. after a suggestion is picked, or the field loses focus).
    func clear() {
        results = []
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

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

    @State private var locationCompleter = LocationSearchCompleter()
    @FocusState private var locationFieldFocused: Bool

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

            // Location — MapKit-backed autocomplete. Typing updates the
            // completer's query; tapping a suggestion fills the text field
            // with the full address and dismisses the results list.
            fieldRow(label: "Location") {
                TextField(bundle.loc("Search for a location"), text: $location)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .focused($locationFieldFocused)
                    .onChange(of: location) { _, newValue in
                        locationCompleter.search(newValue)
                    }
                    // Clear stale results on blur (not just hide them) — otherwise
                    // an old suggestion list flashes back the instant focus
                    // returns, before any new typing has re-queried.
                    .onChange(of: locationFieldFocused) { _, isFocused in
                        if !isFocused { locationCompleter.clear() }
                    }
            }
            if locationFieldFocused && !locationCompleter.results.isEmpty {
                locationResultsList
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

    /// Dropdown of place suggestions shown under the location field while it
    /// has focus and the completer has results. Each row shows the
    /// completion's title (bold) + subtitle, matching MapKit's own
    /// `MKLocalSearchCompletion` shape.
    private var locationResultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(locationCompleter.results.enumerated()), id: \.offset) { _, result in
                Button {
                    selectLocation(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .lineLimit(1)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if result.title != locationCompleter.results.last?.title {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(AppColors.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Fills `location` from a tapped suggestion (title + subtitle joined,
    /// e.g. "Coffee House, 123 Main St, City") and dismisses the results list.
    private func selectLocation(_ result: MKLocalSearchCompletion) {
        location = result.subtitle.isEmpty ? result.title : "\(result.title), \(result.subtitle)"
        locationCompleter.clear()
        locationFieldFocused = false
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
            field()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppColors.elevated(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
