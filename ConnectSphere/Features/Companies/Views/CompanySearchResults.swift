import SwiftUI

/// Search's Companies tab (Work mode): pages matching the text, and a way to
/// create one for a company that isn't here yet.
struct CompanySearchResults: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let query: String
    @State private var viewModel = CompanySearchViewModel()
    @State private var showCreate = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        VStack(spacing: 10) {
            Button { showCreate = true } label: {
                Label(bundle.loc("Create a company page"), systemImage: "plus.square.on.square")
                    .scaledFont(15, .semibold)
                    .foregroundColor(themeManager.theme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(themeManager.theme.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            if viewModel.isLoading && viewModel.results.isEmpty {
                ProgressView().padding(.vertical, 24)
            } else if viewModel.results.isEmpty {
                Text(query.isEmpty ? bundle.loc("No company pages yet.") : bundle.loc("No companies match."))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.vertical, 24)
            } else {
                ForEach(viewModel.results) { company in
                    NavigationLink {
                        CompanyPageView(companyId: company.id, preloaded: company) { viewModel.upsert($0) }
                    } label: {
                        CompanyRow(company: company)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { viewModel.search(query, token: token) }
        .onChange(of: query) { _, q in viewModel.search(q, token: token) }
        .sheet(isPresented: $showCreate) {
            CompanyEditorView { viewModel.upsert($0) }
        }
    }
}
