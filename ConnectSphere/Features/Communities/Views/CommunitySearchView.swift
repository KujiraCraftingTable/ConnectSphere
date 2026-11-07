import SwiftUI

/// Full-screen search inside a community, like a Facebook group's: back arrow
/// and field up top with the keyboard already open, recent searches and
/// suggestions underneath, and the matching posts after Enter.
struct CommunitySearchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: CommunitySearchViewModel
    @State private var detailRoute: PostRoute?
    @FocusState private var fieldFocused: Bool

    let communityName: String
    let communityId: String

    init(communityId: String, communityName: String, token: String, seedPosts: [Post]) {
        self.communityId = communityId
        self.communityName = communityName
        _viewModel = State(initialValue: CommunitySearchViewModel(
            communityId: communityId, token: token, seedPosts: seedPosts))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                content
            }
            .background(AppColors.surface(colorScheme).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(
                get: { detailRoute != nil },
                set: { if !$0 { detailRoute = nil } }
            )) {
                if let route = detailRoute {
                    PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
                }
            }
        }
        .task {
            // Let the cover finish presenting, or the keyboard is dropped.
            try? await Task.sleep(nanoseconds: 350_000_000)
            fieldFocused = true
        }
    }

    // MARK: Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .frame(width: 36, height: 44)
            }
            .accessibilityLabel(Text("Back", bundle: bundle))

            HStack(spacing: 8) {
                TextField("", text: $viewModel.query,
                          prompt: Text(String(format: bundle.loc("Search in %@"), communityName)))
                    .textInputAutocapitalization(.never)
                    // A search is the user's own words; autocorrect once turned "qa" into "as".
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($fieldFocused)
                    .onSubmit {
                        fieldFocused = false
                        Task { await viewModel.submit() }
                    }
                if !viewModel.query.isEmpty {
                    Button { viewModel.query = ""; fieldFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear", bundle: bundle))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppColors.elevated(colorScheme), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: viewModel.query) { _, _ in viewModel.queryChanged() }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if viewModel.showsResults {
            resultsList
        } else {
            suggestionsList
        }
    }

    private var suggestionsList: some View {
        List {
            if viewModel.trimmedQuery.isEmpty && !viewModel.recents.isEmpty {
                Section {
                    ForEach(viewModel.recents, id: \.self) { term in
                        row(term, icon: "clock.arrow.circlepath") {
                            Button { viewModel.forget(term) } label: {
                                Image(systemName: "xmark").font(.system(size: 13))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove", bundle: bundle))
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent searches", bundle: bundle)
                        Spacer()
                        Button { viewModel.clearRecents() } label: { Text("Clear all", bundle: bundle) }
                    }
                }
            }
            if !viewModel.suggestions.isEmpty {
                Section {
                    ForEach(viewModel.suggestions, id: \.self) { term in
                        row(term, icon: "magnifyingglass") { EmptyView() }
                    }
                } header: {
                    if viewModel.trimmedQuery.isEmpty { Text("Popular in this community", bundle: bundle) }
                }
            }
            if viewModel.trimmedQuery.isEmpty && viewModel.recents.isEmpty && viewModel.suggestions.isEmpty {
                Text("No recent searches", bundle: bundle)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row<Trailing: View>(_ term: String, icon: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            fieldFocused = false
            Task { await viewModel.pick(term) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(width: 24)
                Text(term).foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            Spacer()
        } else if viewModel.results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Text(viewModel.errorMessage ?? bundle.loc("No results found"))
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: AppSpacing.sm) {
                    ForEach(viewModel.results) { post in
                        PostCard(
                            post: post,
                            onPostDeleted: { viewModel.removeResult(id: post.id) },
                            onOpenDetail: { focus in
                                detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                            },
                            insideCommunityId: communityId
                        )
                        .cardStyle()
                    }
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(AppColors.base(colorScheme))
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
