import SwiftUI
import UniformTypeIdentifiers

/// Inline section shown inside CreatePostView when post type = Job. Work mode
/// and verified HR only: the company is always the HR's own; captures title,
/// the careers-page link, location, type, pay, skills and deadline.
struct CreateJobSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Binding var title: String
    @Binding var employmentType: EmploymentType?
    @Binding var salaryRange: String
    @Binding var applicationDeadline: Date?
    @Binding var showApplicationDeadline: Bool
    /// The Jobs-tab details (careers link, skills, level, format, pay).
    @Bindable var details: PostComposerViewModel
    @Environment(AppState.self) private var appState
    @State private var pickingJD = false

    private var token: String { appState.authToken ?? "" }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(bundle.loc("Job Details"))

            // Title
            fieldRow(label: bundle.loc("Title") + " *") {
                TextField(bundle.loc("Job title"), text: $title)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }

            // Always the poster's verified HR company (server-enforced).
            // HStack, not Label: a custom Label loses its text in this stack.
            if let company = appState.hrCompany {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.blue)
                    Text(String(format: bundle.loc("Posting for %@"), company))
                        .scaledFont(14, .medium)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
            }

            // The job on the company's own careers page, for applicants to check.
            VStack(alignment: .leading, spacing: 4) {
                fieldRow(label: bundle.loc("Careers page link") + " *") {
                    TextField(bundle.loc("https://yourcompany.com/careers/…"), text: $details.jobCareersUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                }
                Text("Where this job is listed on your company's website, so applicants can check it's real.", bundle: bundle)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }

            // The company's own job description, optional; applicants open it full screen.
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("Job description (PDF)"))
                    .scaledFont(12, .medium)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                if let name = details.jobJDName {
                    fieldBox(HStack(spacing: 8) {
                        Image(systemName: "doc.richtext").foregroundColor(themeManager.theme.primary)
                        Text(name).scaledFont(15).lineLimit(1)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Button { details.removeJD() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .accessibilityLabel(Text(bundle.loc("Remove")))
                    })
                } else if details.isUploadingJD {
                    fieldBox(HStack(spacing: 8) { ProgressView(); Text("Uploading…", bundle: bundle).scaledFont(15) })
                } else {
                    Button { pickingJD = true } label: {
                        fieldBox(HStack(spacing: 8) {
                            Image(systemName: "paperclip")
                            Text(bundle.loc("Attach job description (PDF)")).scaledFont(15)
                            Spacer()
                        }
                        .foregroundColor(themeManager.theme.primary))
                    }
                    .buttonStyle(.plain)
                }
                Text("Optional. PDF, up to 10 MB. Anyone who can see the job can open it.", bundle: bundle)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .fileImporter(isPresented: $pickingJD, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    Task { await details.attachJD(at: url, token: token) }
                }
            }

            // Where the job is: a ward, so "Near you" is real distance, not a
            // shared city name. A remote job has none.
            if details.jobWorkFormat != "remote" {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bundle.loc("Location *"))
                        .scaledFont(12, .medium)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                    WardPickerView(selectedProvinceCode: $details.jobProvinceCode, selectedWardId: $details.jobWardId,
                                   note: bundle.loc("Applicants see the ward and province, and how far it is from their own ward."))
                }
            }

            // Employment type
            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.loc("Employment type"))
                    .scaledFont(12, .medium)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Menu {
                    Button(bundle.loc("None")) { employmentType = nil }
                    ForEach(EmploymentType.allCases, id: \.self) { type in
                        Button(bundle.loc(type.label)) { employmentType = type }
                    }
                } label: {
                    HStack {
                        Text(employmentType.map { bundle.loc($0.label) } ?? bundle.loc("Optional"))
                            .scaledFont(15)
                            .foregroundColor(employmentType == nil
                                ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .scaledFont(12)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AppColors.elevated(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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

            // Pay range, VND million / month, or "Negotiable" instead
            Toggle(bundle.loc("Pay is negotiable"), isOn: $details.jobSalaryNegotiable.animation(.snappy))
                .scaledFont(14)
            if !details.jobSalaryNegotiable {
                HStack(spacing: 10) {
                    fieldRow(label: bundle.loc("Pay from (million ₫/month)")) {
                        TextField(bundle.loc("e.g. 15"), text: $details.jobSalaryMin).keyboardType(.numberPad)
                    }
                    fieldRow(label: bundle.loc("Pay to")) {
                        TextField(bundle.loc("e.g. 30"), text: $details.jobSalaryMax).keyboardType(.numberPad)
                    }
                }
            }
            if !details.jobSalaryValid {
                Text("The pay range needs numbers, the first no higher than the second.", bundle: bundle)
                    .scaledFont(12).foregroundColor(.red)
            }

            // Required skills, matched against people's profiles
            fieldRow(label: bundle.loc("Required skills (up to 10)")) {
                SkillPickerView(skills: $details.jobSkills, limit: SkillList.jobLimit, jobTitle: title, colorScheme: colorScheme)
            }

            Divider()

            // Optional application deadline
            Toggle(isOn: $showApplicationDeadline) {
                Label(bundle.loc("Add application deadline"), systemImage: "calendar.badge.clock")
                    .scaledFont(14)
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
                .scaledFont(14)
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

    // MARK: - Form rows
    private func pickerRow<M: View>(label: String, value: String, @ViewBuilder menu: () -> M) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Menu { menu() } label: {
                HStack {
                    Text(value)
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(12)
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
