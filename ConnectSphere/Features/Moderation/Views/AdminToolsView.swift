import SwiftUI

/// Settings › Admin tools, shown only to the official @connectsphere account:
/// the report review queue, overall counts and looking up one account.
struct AdminToolsView: View {
    @State private var viewModel = AdminToolsViewModel()
    @Environment(\.appBundle) private var bundle

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AppModerationQueueView()
                } label: {
                    Label(bundle.loc("Review reports"), systemImage: "hammer.fill")
                }
                NavigationLink {
                    InterestSuggestionsView()
                } label: {
                    Label(bundle.loc("Interest suggestions"), systemImage: "sparkles")
                }
            }

            // Verified HR (server migration 126): who may post jobs, and a new HR's first jobs.
            Section {
                NavigationLink { HRRequestsView() } label: {
                    Label(bundle.loc("HR requests"), systemImage: "person.badge.shield.checkmark.fill")
                }
                NavigationLink { PendingJobsView() } label: {
                    Label(bundle.loc("Jobs to review"), systemImage: "briefcase.fill")
                }
            } header: {
                Text("Hiring", bundle: bundle)
            }

            Section {
                if let s = viewModel.stats {
                    row("Accounts", "\(s.accounts)")
                    row("New accounts (7 days)", "\(s.newAccounts7d)")
                    row("Profiles", modes(s.profiles))
                    row("Posts", modes(s.posts))
                    row("Posts (7 days)", modes(s.posts7d))
                    row("Open cases", "\(s.openCases)")
                    row("Appeals waiting", "\(s.pendingAppeals)")
                    row("Reports (7 days)", "\(s.reports7d)")
                } else if let err = viewModel.statsError {
                    Text(err).foregroundColor(.red)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Overview", bundle: bundle)
            }

            Section {
                HStack {
                    TextField(bundle.loc("Username"), text: $viewModel.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await viewModel.lookUp() } }
                    Button(bundle.loc("Look up")) { Task { await viewModel.lookUp() } }
                        .disabled(!viewModel.canLookUp)
                }
                if viewModel.isLookingUp { ProgressView() }
                if let err = viewModel.lookupError { Text(err).foregroundColor(.red) }
                if let u = viewModel.found {
                    row("Username", "@\(u.username)")
                    if let name = u.hobbyDisplayName { row("Hobby name", name) }
                    if let name = u.workDisplayName { row("Work name", name) }
                    row("Role", u.appRole)
                    row("Joined", u.createdAt.formatted(date: .abbreviated, time: .omitted))
                    row("Posts", "\(u.posts)")
                    row("Active strikes", "\(u.activeStrikes)")
                    row("Open cases", "\(u.openCases)")
                    if u.deletedAt != nil { row("Status", bundle.loc("Deleted")) }
                    else if u.bannedAt != nil { row("Status", bundle.loc("Suspended")) }
                    else if let until = u.restrictedUntil {
                        row("Status", String(format: bundle.loc("Read-only until %@"),
                                             until.formatted(date: .abbreviated, time: .shortened)))
                    }
                }
            } header: {
                Text("Look up an account", bundle: bundle)
            } footer: {
                Text("Shows no email, phone, birthday or messages.", bundle: bundle)
            }
        }
        .navigationTitle(Text("Admin tools", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadStats() }
        .refreshable { await viewModel.loadStats() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(bundle.loc(label), value: value)
    }

    private func modes(_ c: AdminStats.ModeCounts) -> String {
        String(format: bundle.loc("Hobby %lld · Work %lld"), c.hobby, c.work)
    }
}
