import SwiftUI

/// One job: what, where, pay, the skills it needs (yours ticked, the rest
/// to build), the description, who posted it, and Save / Apply (or, for
/// whoever's hiring, its applicants).
struct JobDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: JobDetailViewModel
    @State private var applying = false
    @Environment(\.openURL) private var openURL
    @State private var inAppBrowserURL: URL?
    /// The job description PDF, open full screen.
    @State private var viewingJD: URL?
    @State private var reportSubject: ReportSubject?
    let onChange: (JobListing) -> Void

    init(jobId: String, preloaded: JobListing? = nil, onChange: @escaping (JobListing) -> Void) {
        _viewModel = State(initialValue: JobDetailViewModel(jobId: jobId, preloaded: preloaded))
        self.onChange = onChange
    }

    private var token: String { appState.authToken ?? "" }

    // MARK: - Body
    var body: some View {
        ScrollView {
            if let job = viewModel.job {
                VStack(alignment: .leading, spacing: 12) {
                    header(job)
                    if !job.skills.isEmpty { skills(job) }
                    if let text = job.description, !text.isEmpty {
                        card(bundle.loc("About the job")) {
                            Text(job.descriptionFormat == "markdown"
                                 ? MarkdownFormatter.attributed(text, linkColor: themeManager.theme.primary,
                                                                quoteColor: AppColors.textSecondary(colorScheme))
                                 : AttributedString(text))
                                .scaledFont(15)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                                .environment(\.openURL, OpenURLAction { url in
                                    if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                                        inAppBrowserURL = url
                                    } else {
                                        openURL(url)
                                    }
                                    return .handled
                                })
                        }
                    }
                    if let path = job.jdPath, let url = APIConfig.mediaURL(path) { jdCard(url) }
                    if let link = job.careersUrl, !link.isEmpty { careersCard(link) }
                    card(bundle.loc("Posted by")) {
                        NavigationLink { UserProfileView(userId: job.poster.id) } label: {
                            HStack(spacing: 10) {
                                Avatar(name: job.poster.displayName, colorHex: job.poster.avatarColor,
                                       imageURL: job.poster.avatarUrl, size: .md)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(job.poster.displayName)
                                            .scaledFont(15, .semibold)
                                            .foregroundColor(AppColors.textPrimary(colorScheme))
                                        if let company = job.poster.hrCompany { HRBadge(company: company) }
                                    }
                                    if let title = job.poster.jobTitle {
                                        Text(title).scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
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
        .inAppBrowser(url: $inAppBrowserURL)
        // A job's own page: the Save / Apply bar takes the bottom, not the tabs.
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: Binding(get: { viewingJD != nil }, set: { if !$0 { viewingJD = nil } })) {
            if let url = viewingJD { PDFViewerScreen(url: url, title: bundle.loc("Job description")) }
        }
        .navigationTitle(bundle.loc("Job"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job = viewModel.job, !job.isMine {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            reportSubject = .content(.post, id: job.postId)
                        } label: {
                            Label(bundle.loc("Report job"), systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(Text(bundle.loc("More")))
                }
            }
        }
        .sheet(item: $reportSubject) { ReportSheet(subject: $0) }
        .safeAreaInset(edge: .bottom) {
            if let job = viewModel.job { actions(job) }
        }
        .task { await viewModel.load(token: token) }
        .onChange(of: viewModel.job) { _, job in if let job { onChange(job) } }
        .sheet(isPresented: $applying) {
            if let job = viewModel.job { ApplySheet(job: job) { viewModel.applied($0) } }
        }
    }

    // MARK: - JD & careers links
    /// The company's own job description, opened full screen in the app.
    private func jdCard(_ url: URL) -> some View {
        card(bundle.loc("Job description")) {
            Button { viewingJD = url } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext").scaledFont(22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Job description (PDF)", bundle: bundle).scaledFont(15, .semibold)
                        Text("Tap to read", bundle: bundle).scaledFont(12)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(AppColors.textTertiary(colorScheme))
                }
                .foregroundColor(themeManager.theme.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The job on the company's own site: applicants open it and check the
    /// address is really the company's before applying. Shown as typed; not
    /// checked against the HR's domain yet (KNOWN_GAPS).
    private func careersCard(_ link: String) -> some View {
        card(bundle.loc("Check on the company's careers page")) {
            VStack(alignment: .leading, spacing: 6) {
                if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                   let host = url.host {
                    Button { inAppBrowserURL = url } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "safari")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host).scaledFont(15, .semibold)
                                Text(link).scaledFont(12).lineLimit(1)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                        .foregroundColor(themeManager.theme.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(link).scaledFont(15).foregroundColor(AppColors.textPrimary(colorScheme)).textSelection(.enabled)
                }
                Text("Make sure this is the company's real website. Never pay anyone to apply or get a job.", bundle: bundle)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
    }

    // MARK: - Header & skills
    private func header(_ job: JobListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Avatar(name: job.companyName ?? job.poster.displayName,
                       imageURL: job.companyLogoUrl ?? job.poster.avatarUrl, size: .lg, shape: .roundedSquare)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .scaledFont(20, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    companyLine(job)
                }
            }
            Text(job.salaryText(loc: bundle.loc) ?? bundle.loc("Negotiable"))
                .scaledFont(16, .semibold)
                .foregroundColor(themeManager.theme.primary)
            let facts = [job.location.map(bundle.address), job.distanceKm.map { "~" + String(format: bundle.loc("%d km"), $0) }, job.workFormat.map { bundle.loc(JobListing.formatLabel($0)) },
                         job.level.map { bundle.loc(JobListing.levelLabel($0)) },
                         job.employmentType.flatMap(EmploymentType.init(rawValue:)).map { bundle.loc($0.label) }]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            HStack {
                if !job.isMine, let reason = job.matchText(loc: bundle.loc) {
                    Label(reason, systemImage: "sparkles")
                        .scaledFont(13, .medium)
                        .foregroundColor(themeManager.theme.primary)
                }
                Spacer()
                if let deadline = job.deadlineDate {
                    Text(String(format: bundle.loc("Apply by %@"), deadline.formatted(date: .abbreviated, time: .omitted)))
                        .scaledFont(12)
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
                .scaledFont(15)
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
                        .scaledFont(13, .medium)
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
                .scaledFont(16, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Save & apply bar
    private func actions(_ job: JobListing) -> some View {
        HStack(spacing: 10) {
            if let count = job.applicantCount {
                NavigationLink { ApplicantsView(jobId: job.id) } label: {
                    Label(String(format: bundle.loc("Applicants (%lld)"), count), systemImage: "person.2")
                        .scaledFont(15, .semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button { Task { await viewModel.toggleSave(token: token) } } label: {
                    Label(bundle.loc(job.saved ? "Saved" : "Save"), systemImage: job.saved ? "bookmark.fill" : "bookmark")
                        .scaledFont(15, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                if let status = job.applicationStatus {
                    Label(bundle.loc(JobApplication.statusLabel(status)), systemImage: JobApplication.statusIcon(status))
                        .scaledFont(15, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                } else {
                    Button { applying = true } label: {
                        Label(bundle.loc("Apply"), systemImage: "paperplane.fill")
                            .scaledFont(15, .semibold)
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
