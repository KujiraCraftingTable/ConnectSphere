import SwiftUI

/// Inline section shown inside CreatePostView when post type = Poll.
/// Lets the user enter 2–6 options and an optional end date.
struct CreatePollSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Binding var options: [String]
    @Binding var endsAt: Date?
    @Binding var showEndDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(bundle.loc("Poll Options"))

            ForEach(options.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1).")
                        .scaledFont(14, .medium)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .frame(width: 22, alignment: .trailing)

                    TextField(String(format: bundle.loc("Option %d"), i + 1), text: $options[i])
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(AppColors.elevated(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    if options.count > 2 {
                        Button {
                            options.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                                .scaledFont(20)
                        }
                        .accessibilityLabel(Bundle.app.loc("Remove option"))
                        .buttonStyle(.plain)
                    }
                }
            }

            if options.count < 6 {
                Button {
                    options.append("")
                } label: {
                    Label(bundle.loc("Add option"), systemImage: "plus.circle")
                        .scaledFont(14, .medium)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
            }

            Divider()

            // Optional end date toggle
            Toggle(isOn: $showEndDate) {
                Label(bundle.loc("Poll end date"), systemImage: "clock")
                    .scaledFont(14)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(themeManager.theme.primary)

            if showEndDate {
                DatePicker(
                    bundle.loc("Ends at"),
                    selection: Binding(
                        get:  { endsAt ?? Date().addingTimeInterval(86400) },
                        set:  { endsAt = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .scaledFont(14)
                .onAppear { if endsAt == nil { endsAt = Date().addingTimeInterval(86400) } }
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
}
