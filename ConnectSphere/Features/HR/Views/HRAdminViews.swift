import SwiftUI

// MARK: - Requests list
/// Admin tools › HR requests: who asked to become a company's verified HR.
struct HRRequestsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = HRRequestsViewModel()

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            if let error = viewModel.errorMessage { Text(error).foregroundColor(.red) }
            ForEach(viewModel.requests) { r in
                NavigationLink {
                    HRRequestDetailView(request: r) { Task { await viewModel.load(token: token) } }
                } label: {
                    HStack(spacing: 12) {
                        Avatar(name: r.person.displayName, colorHex: r.person.avatarColor,
                               imageURL: r.person.avatarUrl, size: .md)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.companyName).scaledFont(15, .semibold)
                            Text("\(r.person.displayName) · @\(r.person.username)")
                                .scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
                            if let other = r.conflictWith {
                                Text(String(format: bundle.loc("Already HR: %@"), other))
                                    .scaledFont(12, .semibold).foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.requests.isEmpty {
                ProgressView()
            } else if !viewModel.isLoading && viewModel.requests.isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(systemImage: "person.badge.shield.checkmark", title: bundle.loc("No requests"))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("", selection: $viewModel.tab) {
                Text("Waiting", bundle: bundle).tag(HRRequestsViewModel.Tab.pending)
                Text("Approved", bundle: bundle).tag(HRRequestsViewModel.Tab.approved)
                Text("Rejected", bundle: bundle).tag(HRRequestsViewModel.Tab.rejected)
                Text("Revoked", bundle: bundle).tag(HRRequestsViewModel.Tab.revoked)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .navigationTitle(Text("HR requests", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: viewModel.tab) { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
    }
}

// MARK: - Request detail
/// One request: the details, the business registration, the checks, and the decision.
struct HRRequestDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: HRRequestDetailViewModel
    @State private var confirming: Action?
    let onDecided: () -> Void

    enum Action: Identifiable { case approve, reject, revoke; var id: Self { self } }

    init(request: HRRequestItem, onDecided: @escaping () -> Void) {
        _viewModel = State(initialValue: HRRequestDetailViewModel(request: request))
        self.onDecided = onDecided
    }

    private var token: String { appState.authToken ?? "" }
    private var r: HRRequestItem { viewModel.request }

    var body: some View {
        Form {
            Section {
                LabeledContent(bundle.loc("Company"), value: r.companyName)
                LabeledContent(bundle.loc("Tax code"), value: r.taxCode)
                LabeledContent(bundle.loc("Website"), value: r.website)
                LabeledContent(bundle.loc("Company email"), value: r.workEmail)
                LabeledContent(bundle.loc("Person"), value: "\(r.person.displayName) · @\(r.person.username)")
                if let url = APIConfig.mediaURL(r.licencePath) {
                    Button { openURL(url) } label: {
                        Label(bundle.loc("Open business registration (PDF)"), systemImage: "doc.richtext")
                    }
                }
            } footer: {
                if let other = r.conflictWith {
                    Text(String(format: bundle.loc("%@ is already HR for this tax code. Only one HR per company, so this can't be approved."), other))
                        .foregroundColor(.red)
                }
            }

            if r.status == "pending" {
                Section {
                    ForEach(HRRequestDetailViewModel.checks, id: \.key) { check in
                        Toggle(bundle.loc(check.label), isOn: Binding(
                            get: { viewModel.isChecked(check.key) },
                            set: { viewModel.setChecked(check.key, $0) }))
                    }
                } header: {
                    Text("Before approving", bundle: bundle)
                } footer: {
                    Text("Look the tax code up on the national business registry, compare the name with the PDF, and open the website. If anything's unclear, contact the company using the details on its official website, not those in the request.", bundle: bundle)
                }
            } else if let note = r.reviewNote {
                Section(bundle.loc("Note")) { Text(note) }
            }

            if r.status == "pending" || r.status == "approved" {
                Section {
                    TextField(bundle.loc(r.status == "pending" ? "Reason (required to reject)" : "Reason (required)"),
                              text: $viewModel.note, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("The person reads this.", bundle: bundle)
                }
                Section {
                    if r.status == "pending" {
                        Button(bundle.loc("Approve as HR")) { confirming = .approve }
                            .disabled(!viewModel.canApprove)
                        Button(bundle.loc("Reject"), role: .destructive) { confirming = .reject }
                            .disabled(!viewModel.canReject)
                    } else {
                        Button(bundle.loc("Revoke HR"), role: .destructive) { confirming = .revoke }
                            .disabled(!viewModel.canRevoke)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundColor(.red) }
            }
        }
        .navigationTitle(r.companyName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let action = confirming {
                Button(bundle.loc(action == .approve ? "Approve" : action == .reject ? "Reject" : "Revoke"),
                       role: action == .approve ? nil : .destructive) {
                    Task {
                        let done: Bool
                        switch action {
                        case .approve: done = await viewModel.decide(approve: true, token: token)
                        case .reject: done = await viewModel.decide(approve: false, token: token)
                        case .revoke: done = await viewModel.revoke(token: token)
                        }
                        if done { onDecided(); dismiss() }
                    }
                }
            }
        }
    }

    private var confirmTitle: String {
        switch confirming {
        case .approve: String(format: bundle.loc("Make %@ the verified HR for %@?"), r.person.displayName, r.companyName)
        case .reject: bundle.loc("Reject this request?")
        case .revoke: bundle.loc("Revoke HR? Their jobs are removed and everyone who applied is told.")
        case nil: ""
        }
    }
}

// MARK: - Pending jobs
/// Admin tools › Jobs to review: a new HR's first jobs, before they go live.
struct PendingJobsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = PendingJobsViewModel()
    @State private var declining: PendingJobItem?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            if let error = viewModel.errorMessage { Text(error).foregroundColor(.red) }
            ForEach(viewModel.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).scaledFont(16, .semibold)
                    Text("\(job.company ?? "") · \(job.person.displayName) (@\(job.person.username))")
                        .scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
                    if let link = job.careersUrl {
                        Label(link, systemImage: "link").scaledFont(13).lineLimit(1)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    if let text = job.description, !text.isEmpty {
                        Text(text).scaledFont(14).lineLimit(6)
                    }
                    HStack {
                        Button(bundle.loc("Approve")) { Task { await viewModel.decide(job, approve: true, token: token) } }
                            .buttonStyle(.borderedProminent)
                        Button(bundle.loc("Decline"), role: .destructive) { declining = job }
                            .buttonStyle(.bordered)
                        if viewModel.workingOn == job.id { ProgressView() }
                    }
                    .disabled(viewModel.workingOn != nil)
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.jobs.isEmpty {
                ProgressView()
            } else if !viewModel.isLoading && viewModel.jobs.isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(systemImage: "briefcase", title: bundle.loc("No jobs to review"))
            }
        }
        .navigationTitle(Text("Jobs to review", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
        .alert(bundle.loc("Decline this job?"), isPresented: Binding(get: { declining != nil }, set: { if !$0 { declining = nil } })) {
            TextField(bundle.loc("Reason the HR will read"), text: $viewModel.declineReason)
            Button(bundle.loc("Decline"), role: .destructive) {
                if let job = declining { Task { await viewModel.decide(job, approve: false, token: token) } }
            }
            .disabled(!viewModel.canDecline)
            Button(bundle.loc("Cancel"), role: .cancel) { }
        }
    }
}
