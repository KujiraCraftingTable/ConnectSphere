import SwiftUI

/// Work mode's Jobs tab: For you (best matches with why), Search with
/// filters, Saved, and Applied. Communities live behind the toolbar button here.
struct JobsHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let onOpenCommunities: () -> Void
    @State private var viewModel = JobsHomeViewModel()
    @State private var showFilters = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    Picker("", selection: $viewModel.segment) {
                        Text("For you", bundle: bundle).tag(JobsHomeViewModel.Segment.forYou)
                        Text("Search", bundle: bundle).tag(JobsHomeViewModel.Segment.search)
                        Text("Saved", bundle: bundle).tag(JobsHomeViewModel.Segment.saved)
                        Text("Applied", bundle: bundle).tag(JobsHomeViewModel.Segment.applied)
                    }
                    .pickerStyle(.segmented)

                    if viewModel.segment == .search { searchBar }
                    if viewModel.segment == .forYou {
                        Text("Picked from your skills, experience and where you are.", bundle: bundle)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if viewModel.isLoading {
                        ProgressView().padding(.top, 40)
                    } else if let error = viewModel.errorMessage, viewModel.isEmpty {
                        Text(error).foregroundColor(AppColors.textSecondary(colorScheme)).padding(.top, 40)
                    } else if viewModel.isEmpty {
                        emptyState
                    } else if viewModel.segment == .applied {
                        ForEach(viewModel.applications) { application in
                            NavigationLink {
                                JobDetailView(jobId: application.jobId) { viewModel.updated($0) }
                            } label: {
                                MyApplicationCard(application: application)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(viewModel.shown) { job in
                            NavigationLink {
                                JobDetailView(jobId: job.id, preloaded: job) { viewModel.updated($0) }
                            } label: {
                                JobCard(job: job, showsMatch: viewModel.segment != .saved) {
                                    Task { await viewModel.toggleSave(job, token: token) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Jobs"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenCommunities) { Image(systemName: "person.3") }
                        .accessibilityLabel(Text(bundle.loc("Communities")))
                }
            }
            .refreshable { await viewModel.load(token: token) }
            .task(id: viewModel.segment) { await viewModel.load(token: token) }
            .onChange(of: viewModel.filters) { _, _ in viewModel.searchSoon(token: token) }
            .sheet(isPresented: $showFilters) { JobFiltersSheet(filters: $viewModel.filters) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(AppColors.textTertiary(colorScheme))
                TextField(bundle.loc("Title, company or skill"), text: $viewModel.filters.query)
                    .submitLabel(.search)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(AppColors.elevated(colorScheme), in: Capsule())
            Button { showFilters = true } label: {
                Image(systemName: viewModel.filters.isEmpty || viewModel.filters == .init(query: viewModel.filters.query)
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(themeManager.theme.primary)
            }
            .accessibilityLabel(Text(bundle.loc("Filters")))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "briefcase")
                .font(.system(size: 34))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(emptyText)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 50)
        .padding(.horizontal, 24)
    }

    private var emptyText: String {
        switch viewModel.segment {
        case .forYou: bundle.loc("No open jobs to suggest yet. Add skills and experience to your profile for better matches.")
        case .search: bundle.loc("No jobs match.")
        case .saved: bundle.loc("Jobs you save show here.")
        case .applied: bundle.loc("Jobs you apply to show here, with where each application stands.")
        }
    }
}

/// Narrow the job search: place, type, format, level, pay.
struct JobFiltersSheet: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: JobsRepository.Filters

    var body: some View {
        NavigationStack {
            Form {
                LocationSearchField(bundle.loc("Location (e.g. Ho Chi Minh City)"), text: $filters.location)
                Picker(bundle.loc("Employment type"), selection: $filters.employmentType) {
                    Text("Any", bundle: bundle).tag(EmploymentType?.none)
                    ForEach(EmploymentType.allCases, id: \.self) { Text(bundle.loc($0.label)).tag(EmploymentType?.some($0)) }
                }
                Picker(bundle.loc("Work format"), selection: $filters.workFormat) {
                    Text("Any", bundle: bundle).tag(String?.none)
                    ForEach(JobListing.formats, id: \.self) { Text(bundle.loc(JobListing.formatLabel($0))).tag(String?.some($0)) }
                }
                Picker(bundle.loc("Level"), selection: $filters.level) {
                    Text("Any", bundle: bundle).tag(String?.none)
                    ForEach(JobListing.levels, id: \.self) { Text(bundle.loc(JobListing.levelLabel($0))).tag(String?.some($0)) }
                }
                Picker(bundle.loc("Pay at least"), selection: $filters.salaryMin) {
                    Text("Any", bundle: bundle).tag(Int?.none)
                    ForEach([5, 10, 15, 20, 30, 50], id: \.self) {
                        Text(String(format: bundle.loc("%lld million ₫/month"), $0)).tag(Int?.some($0))
                    }
                }
                Section {
                    Button(bundle.loc("Clear filters"), role: .destructive) {
                        filters = JobsRepository.Filters(query: filters.query)
                    }
                }
            }
            .navigationTitle(bundle.loc("Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(bundle.loc("Done")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A company page's Jobs tab.
struct CompanyJobsList: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let companyId: String
    @State private var viewModel = CompanyJobsViewModel()

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.loaded {
                ProgressView().padding(32)
            } else if viewModel.jobs.isEmpty {
                Text("No open jobs right now.", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(32)
            } else {
                ForEach(viewModel.jobs) { job in
                    NavigationLink {
                        JobDetailView(jobId: job.id, preloaded: job) { _ in }
                    } label: {
                        JobCard(job: job, showsMatch: true) {}
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .task { await viewModel.load(companyId: companyId, token: appState.authToken ?? "") }
    }
}
