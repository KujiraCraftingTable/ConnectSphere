import SwiftUI

struct PrivacyPickerSheet: View {
    @Binding var selected: PostPrivacy
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationStack {
            List {
                ForEach(PostPrivacy.allCases, id: \.self) { option in
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
                                    .font(.system(size: 18))
                                    .foregroundColor(selected == option ? .blue : AppColors.textSecondary(colorScheme))
                            }

                            // Label + description
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Text(option.description)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }

                            Spacer()

                            if selected == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(bundle.loc("Ai có thể xem?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xong") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
