import SwiftUI

/// One job: what, where, pay, the skills it needs (yours ticked, the rest
/// to build), the description, who posted it — and Save / Apply (or, for
/// whoever's hiring, its applicants).
struct JobDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: JobDetailViewModel
    @State private var applying = false
    let onChange: (JobListing) -> Void

    init(jobId: String, preloaded: JobListing? = nil, onChange: @escaping (JobListing) -> Void) {
        _viewModel = State(initialValue: JobDetailViewModel(jobId: jobId, preloaded: preloaded))
        self.onChange = onChange
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        ScrollView {
            if let job = viewModel.job {
                VStack(alignment: .leading, spacing: 12) {
                    header(job)
                    if !job.skills.isEmpty { skills(job) }
                    if let text = job.description, !text.isEmpty {
                        card(bundle.loc("About the job")) {
                            Text(text)
                                .font(.system(size: 15))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    card(bundle.loc("Posted by")) {
                        NavigationLink { UserProfileView(userId: job.poster.id) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: job.poster.displayName, colorHex: job.poster.avatarColor,
                                       imageURL: job.poster.avatarUrl, size: .md)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.poster.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                    if let title = job.poster.jobTitle {
                                        Text(title).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(AppColors.textTertiary(colorScheme))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            } else if viewModel.isLoading {
                ProgressView().padding(.top, 80)
            } else if let error = viewModel.errorMessage {
                Text(error).foregroundColor(AppColors.textSecondary(colorScheme)).padding(.top, 80)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Job"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let job = viewModel.job { actions(job) }
        }
        .task { await viewModel.load(token: token) }
        .onChange(of: viewModel.job) { _, job in if let job { onChange(job) } }
        .sheet(isPresented: $applying) {
            if let job = viewModel.job { ApplySheet(job: job) { viewModel.applied($0) } }
        }
    }

    private func header(_ job: JobListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Avatar(name: job.companyName ?? job.poster.displayName,
                       imageURL: job.companyLogoUrl ?? job.poster.avatarUrl, size: .lg, shape: .roundedSquare)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    companyLine(job)
                }
            }
            Text(job.salaryText(loc: bundle.loc) ?? bundle.loc("Negotiable"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
            let facts = [job.location, job.workFormat.map { bundle.loc(JobListing.formatLabel($0)) },
                         job.level.map { bundle.loc(JobListing.levelLabel($0)) },
                         job.employmentType.flatMap(EmploymentType.init(rawValue:)).map { bundle.loc($0.label) }]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            HStack {
                if !job.isMine {
                    Label(job.matchText(loc: bundle.loc), systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(themeManager.theme.primary)
                }
                Spacer()
                if let deadline = job.deadlineDate {
                    Text(String(format: bundle.loc("Apply by %@"), deadline.formatted(date: .abbreviated, time: .omitted)))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func companyLine(_ job: JobListing) -> some View {
        let line = HStack(spacing: 4) {
            Text(job.companyName ?? job.poster.displayName)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            if job.companyVerified { OfficialBadge(compact: true) }
        }
        if let id = job.companyId {
            NavigationLink { CompanyPageView(companyId: id) } label: { line }.buttonStyle(.plain)
        } else {
            line
        }
    }

    /// Your skills ticked, the rest marked to build.
    private func skills(_ job: JobListing) -> some View {
        card(job.isMine ? bundle.loc("Skills") : String(format: bundle.loc("%lld of %lld skills match"),
                                                        job.match.matchedSkills.count, job.skills.count)) {
            FlowLayout(spacing: 6) {
                ForEach(job.skills, id: \.self) { skill in
                    let have = job.match.matchedSkills.contains(skill)
                    Label(skill, systemImage: have ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(have && !job.isMine ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((have && !job.isMine ? themeManager.theme.primary.opacity(0.1) : AppColors.elevated(colorScheme)),
                                    in: Capsule())
                }
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
    }

    private func actions(_ job: JobListing) -> some View {
        HStack(spacing: 10) {
            if let count = job.applicantCount {
                NavigationLink { ApplicantsView(jobId: job.id) } label: {
                    Label(String(format: bundle.loc("Applicants (%lld)"), count), systemImage: "person.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button { Task { await viewModel.toggleSave(token: token) } } label: {
                    Label(bundle.loc(job.saved ? "Saved" : "Save"), systemImage: job.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                if let status = job.applicationStatus {
                    Label(bundle.loc(JobApplication.statusLabel(status)), systemImage: JobApplication.statusIcon(status))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                } else {
                    Button { applying = true } label: {
                        Label(bundle.loc("Apply"), systemImage: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(themeManager.theme.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
