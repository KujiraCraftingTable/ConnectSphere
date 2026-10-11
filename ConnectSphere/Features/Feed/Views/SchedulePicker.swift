import SwiftUI

/// Pick when a post goes out. "Remove schedule" sends it back to posting now.
struct SchedulePickerSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let initial: Date?
    let onSet: (Date?) -> Void

    @State private var date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.md) {
                DatePicker("", selection: $date, in: ScheduleWindow.range(), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .tint(themeManager.theme.primary)
                Text("Your post goes out at this time, in your time zone. You can change or cancel it from Settings → Drafts.", bundle: bundle)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                    .multilineTextAlignment(.center)
                if initial != nil {
                    Button(role: .destructive) { onSet(nil); dismiss() } label: {
                        Text("Remove schedule", bundle: bundle).font(.system(size: 15, weight: .semibold))
                    }
                }
                Spacer()
            }
            .padding(AppSpacing.lg)
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Schedule post"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Set")) { onSet(date); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { date = initial ?? ScheduleWindow.suggested() }
    }
}

/// "Goes out 14 Oct, 09:00" under the composer, with ✕ to post now instead.
struct ScheduleLine: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    let date: Date
    let onEdit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onEdit) {
                Label(String(format: bundle.loc("Goes out %@"), date.formatted(.dateTime.day().month(.abbreviated).hour().minute())),
                      systemImage: "clock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .buttonStyle(.plain)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove schedule", bundle: bundle))
        }
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
    }
}
