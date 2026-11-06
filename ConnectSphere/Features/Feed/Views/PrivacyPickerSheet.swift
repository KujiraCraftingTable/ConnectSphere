import SwiftUI

struct PrivacyPickerSheet: View {
    @Binding var selected: PostPrivacy
    /// Current mode, determines the wording for the "friends" level (Friends / Connections)
    var mode: AppMode = .hobby
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    private let options = PostPrivacy.allCases

    var body: some View {
        NavigationStack {
            List {
                ForEach(options, id: \.self) { option in
                    Button {
                        selected = option
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            // Icon
                            ZStack {
                                Circle()
                                    .fill(selected == option
                                          ? Color.blue.opacity(0.15)
                                          : AppColors.base(colorScheme))
                                    .frame(width: 44, height: 44)
                                Image(systemName: option.icon)
                                    .scaledFont(18)
                                    .foregroundColor(selected == option ? .blue : AppColors.textSecondary(colorScheme))
                            }

                            // Label + description
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label(for: mode))
                                    .scaledFont(15, .medium)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Text(option.description(for: mode))
                                    .scaledFont(13)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }

                            Spacer()

                            if selected == option {
                                Image(systemName: "checkmark")
                                    .scaledFont(14, .semibold)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(bundle.loc("Who can see this?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
