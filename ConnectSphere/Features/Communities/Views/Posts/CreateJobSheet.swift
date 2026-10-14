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
    /// The Jobs-tab details (company page, skills, level, format, pay).
    @Bindable var details: PostComposerViewModel
    @Environment(AppState.self) private var appState

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

            // Post as a company page you run
            if !details.myCompanies.isEmpty {
                pickerRow(label: bundle.loc("Post as"),
                          value: details.myCompanies.first { $0.id == details.jobCompanyId }?.name ?? bundle.loc("Yourself")) {
                    Button(bundle.loc("Yourself")) { details.pickCompany(nil) }
                    ForEach(details.myCompanies) { c in Button(c.name) { details.pickCompany(c) } }
                }
            }

            HStack(spacing: 10) {
                pickerRow(label: bundle.loc("Work format"),
                          value: details.jobWorkFormat.map { bundle.loc(JobListing.formatLabel($0)) } ?? bundle.loc("Optional")) {
                    Button(bundle.loc("None")) { details.jobWorkFormat = nil }
                    ForEach(JobListing.formats, id: \.self) { f in Button(bundle.loc(JobListing.formatLabel(f))) { details.jobWorkFormat = f } }
                }
                pickerRow(label: bundle.loc("Level"),
                          value: details.jobLevel.map { bundle.loc(JobListing.levelLabel($0)) } ?? bundle.loc("Optional")) {
                    Button(bundle.loc("None")) { details.jobLevel = nil }
                    ForEach(JobListing.levels, id: \.self) { l in Button(bundle.loc(JobListing.levelLabel(l))) { details.jobLevel = l } }
                }
            }

            // Pay range, VND million / month
            HStack(spacing: 10) {
                fieldRow(label: bundle.loc("Pay from (million ₫/month)")) {
                    TextField(bundle.loc("e.g. 15"), text: $details.jobSalaryMin).keyboardType(.numberPad)
                }
                fieldRow(label: bundle.loc("Pay to")) {
                    TextField(bundle.loc("e.g. 30"), text: $details.jobSalaryMax).keyboardType(.numberPad)
                }
            }
            if !details.jobSalaryValid {
                Text("The pay range needs numbers, the first no higher than the second.", bundle: bundle)
                    .font(.system(size: 12)).foregroundColor(.red)
            }

            // Required skills, matched against people's profiles
            fieldRow(label: bundle.loc("Required skills (up to 10)")) {
                SkillTagField(skills: $details.jobSkills, limit: SkillList.jobLimit, colorScheme: colorScheme)
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
        .task { await details.loadMyCompanies(token: appState.authToken ?? "") }
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

    private func pickerRow<M: View>(label: String, value: String, @ViewBuilder menu: () -> M) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Menu { menu() } label: {
                HStack {
                    Text(value)
                        .font(.system(size: 15))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
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
