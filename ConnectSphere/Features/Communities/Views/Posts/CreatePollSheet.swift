import SwiftUI

/// Inline section shown inside CommunityCreatePostView when post type = Poll.
/// Lets the user enter 2–6 options and an optional end date.
struct CreatePollSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var options: [String]
    @Binding var endsAt: Date?
    @Binding var showEndDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Poll Options")

            ForEach(options.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1).")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .frame(width: 22, alignment: .trailing)

                    TextField("Option \(i + 1)", text: $options[i])
                        .font(.system(size: 15))
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
                                .font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if options.count < 6 {
                Button {
                    options.append("")
                } label: {
                    Label("Add option", systemImage: "plus.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .buttonStyle(.plain)
                .padding(.leading, 30)
            }

            Divider()

            // Optional end date toggle
            Toggle(isOn: $showEndDate) {
                Label("Poll end date", systemImage: "clock")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(.purple)

            if showEndDate {
                DatePicker(
                    "Ends at",
                    selection: Binding(
                        get:  { endsAt ?? Date().addingTimeInterval(86400) },
                        set:  { endsAt = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .font(.system(size: 14))
                .onAppear { if endsAt == nil { endsAt = Date().addingTimeInterval(86400) } }
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
}
