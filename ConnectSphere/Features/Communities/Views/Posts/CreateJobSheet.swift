import SwiftUI

/// Inline section shown inside CommunityCreatePostView/CreatePostView when
/// post type = Job. Work mode only — captures title, optional company/
/// location/employment type/salary range/application deadline.
struct CreateJobSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Binding var title: String
    @Binding var company: String
    @Binding var location: String
    @Binding var employmentType: EmploymentType?
    @Binding var salaryRange: String
    @Binding var applicationDeadline: Date?
    @Binding var showApplicationDeadline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(bundle.loc("Job Details"))

            // Title
            fieldRow(label: bundle.loc("Title") + " *") {
                TextField(bundle.loc("Job title"), text: $title)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Company
            fieldRow(label: bundle.loc("Company")) {
                TextField(bundle.loc("Optional"), text: $company)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Location
            fieldRow(label: bundle.loc("Location")) {
                TextField(bundle.loc("Optional"), text: $location)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Employment type
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("Employment type"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Menu {
                    Button(bundle.loc("None")) { employmentType = nil }
                    ForEach(EmploymentType.allCases, id: \.self) { type in
                        Button(bundle.loc(type.label)) { employmentType = type }
                    }
                } label: {
                    HStack {
                        Text(employmentType.map { bundle.loc($0.label) } ?? bundle.loc("Optional"))
                            .font(.system(size: 15))
                            .foregroundColor(employmentType == nil
                                ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppColors.elevated(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            // Salary range
            fieldRow(label: bundle.loc("Salary range")) {
                TextField(bundle.loc("e.g. $60k - $80k"), text: $salaryRange)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            Divider()

            // Optional application deadline
            Toggle(isOn: $showApplicationDeadline) {
                Label(bundle.loc("Add application deadline"), systemImage: "calendar.badge.clock")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            .tint(themeManager.theme.primary)

            if showApplicationDeadline {
                DatePicker(
                    bundle.loc("Deadline"),
                    selection: Binding(
                        get: { applicationDeadline ?? Date().addingTimeInterval(7 * 86400) },
                        set: { applicationDeadline = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .font(.system(size: 14))
                .onAppear { if applicationDeadline == nil { applicationDeadline = Date().addingTimeInterval(7 * 86400) } }
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
