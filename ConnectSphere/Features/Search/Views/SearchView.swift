import SwiftUI

/// The app's single search (the Search tab): people and posts, with an AI
/// toggle. Off, keyword search as you type, ranked by relevance on the
/// server. On, the prompt is broken down by the local LLM and results come
/// back with a match %, run on submit since each search is an LLM call.
struct SearchView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = SearchViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText = ""
    /// What the user types when telling us what an unrecognized place actually is.
    @State private var clarifyText = ""
    @State private var isResettingSearch = false
    @State private var detailRoute: PostRoute?
    @State private var showsRefinePrompt = false
    @State private var refineText = ""
    @FocusState private var isFieldFocused: Bool
    @AppStorage("aiSearchEnabled") private var aiEnabled = false
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0

    /// Binding from MainTabView. Resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    private var trimmedText: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var showsAIResults: Bool { !viewModel.lastAIPrompt.isEmpty }

    var body: some View {
        NavigationStack(path: $navPath) {
            // The header sits above the list, not inside it, so the large
            // "Search" title stays put while the results scroll (as in Community).
            VStack(spacing: 0) {
            searchHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    if aiEnabled && trimmedText.isEmpty && !showsAIResults && !viewModel.suggestions.isEmpty {
                        trendingSection
                    }

                    // Warning: parts of the prompt the AI didn't understand / couldn't apply.
                    // Only shown when there's an actual specific error, not a generic suggestion.
                    if !viewModel.searchWarnings.isEmpty {
                        searchWarningsBox(viewModel.searchWarnings)
                    }

                    // AI keywords box. Visible after AI search, scrolls with content
                    if let criteria = viewModel.aiCriteria {
                        aiKeywordsBadge(criteria)
                    }

                    // Gray alias suggestion area, "did you mean …?" for the user to confirm
                    if !viewModel.entitySuggestions.isEmpty {
                        entitySuggestionsBox
                    }

                    LazyVStack(spacing: appState.currentMode == .hobby ? 10 : 8) {
                        if viewModel.scope == .companies {
                            CompanySearchResults(query: trimmedText)
                        } else if viewModel.isLoading && !showsAIResults {
                            VStack(spacing: 4) {
                                ForEach(0..<6, id: \.self) { _ in SkeletonRow(colorScheme: colorScheme) }
                            }
                            .padding(.horizontal, 16).padding(.top, 8)
                        } else if viewModel.error != nil {
                            networkErrorState
                        } else if viewModel.scope == .people {
                            peopleResults
                        } else {
                            postResults
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            }
            // Not under the top safe area: the title and header sit on white like
            // Community's, and only the results area is the grey page colour.
            .background(AppColors.base(colorScheme), ignoresSafeAreaEdges: [.horizontal, .bottom])
            .navigationTitle(bundle.loc("Search"))
            // Large, like the Notifications tab's title.
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(AppColors.surface(colorScheme), for: .navigationBar)
            .overlay {
                // The Kujira loading scene, shown while an AI search runs.
                if viewModel.isLoading && showsAIResults {
                    ZStack(alignment: .top) {
                        AISearchLoadingView()
                            .environment(appState)
                        if !viewModel.quickMatches.isEmpty { quickMatchesCard }
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }
            }
            // `isPresented:` (not `item:`), same reason as FeedView: other
            // screens on this stack may declare the same PostRoute type.
            .navigationDestination(isPresented: Binding(
                get: { detailRoute != nil },
                set: { if !$0 { detailRoute = nil } }
            )) {
                if let route = detailRoute {
                    PostDetailView(postId: route.postId, focusComposer: route.focusComposer)
                }
            }
            .onChange(of: appState.shouldResetSearch) { _, newValue in
                // Re-tapping the "Search" tab while already active → return to the default
                // browse state, clearing all accumulated search/AI search state
                guard newValue else { return }
                resetToBrowse()
                appState.shouldResetSearch = false
                focusFieldSoon()
            }
            .onAppear {
                // Opening the tab with nothing typed goes straight to typing;
                // coming back from a pushed profile keeps the results as they were.
                if searchText.isEmpty { focusFieldSoon() }
            }
            .onChange(of: searchText) { _, query in
                if isResettingSearch { isResettingSearch = false; return }
                // AI runs on submit, not per keystroke, but clearing the field
                // still returns to the browse state.
                if aiEnabled && !query.trimmingCharacters(in: .whitespaces).isEmpty { return }
                viewModel.search(query: query, mode: appState.currentMode)
            }
            .onChange(of: aiEnabled) { _, isOn in
                // Turning AI off re-runs the text as a keyword search; turning
                // it on waits for the user to submit.
                if !isOn { viewModel.search(query: searchText, mode: appState.currentMode) }
            }
            .onChange(of: viewModel.scope) { _, _ in rerunInCurrentScope() }
            .onChange(of: appState.currentMode) { _, mode in
                // Companies are a Work-mode thing.
                if mode == .hobby && viewModel.scope == .companies { viewModel.scope = .people }
                rerunInCurrentScope()
            }
            .task {
                // .task re-runs when the view "reappears" (e.g. popping back from a pushed profile).
                // If this is because the Search tab was re-tapped (shouldResetSearch = true) →
                // reset fully right here rather than waiting on onChange (which could be missed
                // because the view is covered by the pushed profile when the flag was set).
                viewModel.currentUserId = appState.currentUser?.id
                if appState.shouldResetSearch {
                    appState.shouldResetSearch = false
                    resetToBrowse()
                    return
                }
                // Only load on the first pass. Avoids resetting AI results when backing out of a profile via swipe/back button
                guard viewModel.results.isEmpty, viewModel.postResults.isEmpty else { return }
                await viewModel.loadAll(mode: appState.currentMode)
            }
        }
    }

    // MARK: Header, field, AI toggle, scope

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: aiEnabled ? "sparkles" : "magnifyingglass")
                        .scaledFont(15, .medium)
                        .foregroundColor(aiEnabled ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                    TextField("", text: $searchText, prompt: Text(placeholder))
                        .scaledFont(15)
                        .focused($isFieldFocused)
                        .submitLabel(.search)
                        .onSubmit(runAI)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear", bundle: bundle))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                // Grey pill on the white header, like Community's search field.
                .background(AppColors.base(colorScheme), in: Capsule())
                .overlay(
                    Capsule().stroke(aiEnabled ? themeManager.theme.primary : .clear, lineWidth: 1.5)
                )

                aiToggle
            }

            Picker("", selection: Bindable(viewModel).scope) {
                Text("People", bundle: bundle).tag(SearchScope.people)
                Text("Posts", bundle: bundle).tag(SearchScope.posts)
                if appState.currentMode == .work {
                    Text("Companies", bundle: bundle).tag(SearchScope.companies)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // `ignoresSafeAreaEdges: []` keeps the fill inside the header. A plain
        // `.background(color)` extends into the safe area by default, so this
        // pinned header painted up behind the navigation bar and hid the large
        // "Search" title.
        .background(AppColors.surface(colorScheme), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
        .animation(.easeInOut(duration: 0.15), value: aiEnabled)
    }

    /// Capsule switch between keyword and AI search, tinted when on.
    private var aiToggle: some View {
        Button {
            aiEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("AI", bundle: bundle)
            }
            .scaledFont(14, .semibold)
            .foregroundColor(aiEnabled ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(aiEnabled ? AnyShapeStyle(themeManager.theme.primary) : AnyShapeStyle(AppColors.base(colorScheme)),
                        in: Capsule())
            .overlay(Capsule().stroke(aiEnabled ? .clear : AppColors.borderDefault(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("AI search", bundle: bundle))
        .accessibilityValue(Text(aiEnabled ? "On" : "Off", bundle: bundle))
    }

    private var placeholder: String {
        if aiEnabled { return bundle.loc("Describe who or what you're looking for…") }
        if viewModel.scope == .posts { return bundle.loc("Search posts") }
        if viewModel.scope == .companies { return bundle.loc("Search companies") }
        return appState.currentMode == .hobby
            ? bundle.loc("Search by name, interests, location...")
            : bundle.loc("Search by name, skills, company...")
    }

    // MARK: Actions

    private func runAI() {
        // Enter always closes the keyboard; keyword search has already run as they typed.
        isFieldFocused = false
        guard aiEnabled, !trimmedText.isEmpty else { return }
        let km = RadiusScale.snapped(searchRadiusKm)
        let radius = km > 0 ? km : nil
        Task { await viewModel.submitAI(prompt: trimmedText, mode: appState.currentMode, radiusKm: radius) }
    }

    /// Scope or mode changed: run the same query again where it now applies.
    private func rerunInCurrentScope() {
        if aiEnabled && !trimmedText.isEmpty {
            runAI()
        } else {
            viewModel.search(query: searchText, mode: appState.currentMode)
        }
    }

    /// Waits out the tab switch animation. Focusing mid-transition drops the keyboard.
    private func focusFieldSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            isFieldFocused = true
        }
    }

    private func resetToBrowse() {
        isResettingSearch = !searchText.isEmpty
        searchText = ""
        isFieldFocused = false
        viewModel.scope = .people
        viewModel.currentUserId = appState.currentUser?.id
        Task { await viewModel.loadAll(mode: appState.currentMode) }
    }

    // MARK: Results

    /// Name matches over the AI loading scene, while the AI keeps looking.
    private var quickMatchesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick matches", bundle: bundle)
                .scaledFont(13, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            ForEach(viewModel.quickMatches) { user in
                if appState.currentMode == .hobby {
                    FriendSearchCard(user: user)
                } else {
                    ColleagueSearchCard(user: user)
                }
            }
        }
        .padding(12)
        .background(AppColors.base(colorScheme), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var peopleResults: some View {
        // lastAIPrompt marks "an AI search has run", gated on having results
        // so this doesn't collide with the empty/retry states below.
        if !trimmedText.isEmpty && !viewModel.results.isEmpty {
            resultCount(viewModel.results.count)
        }
        if showsAIResults && viewModel.searchSessionId != nil
            && (!viewModel.results.isEmpty || viewModel.isRefining) {
            refineBar
        }
        if viewModel.results.isEmpty && showsAIResults && !viewModel.isLoading {
            if viewModel.aiSearchFailed {
                kujiraRetryState
            } else if !explainsEmptyResult {
                kujiraEmptyState
            }
        } else if viewModel.results.isEmpty && !trimmedText.isEmpty && !viewModel.isLoading {
            emptyKeywordState
        } else {
            ForEach(viewModel.results) { user in
                Group {
                    // AI search results → mini CV with match reasons; regular search keeps the old card
                    if showsAIResults {
                        MiniCVCard(user: user, evidence: viewModel.matchEvidence[user.id] ?? [],
                                   fitReason: viewModel.fitReasons[user.id],
                                   onOpen: { viewModel.didOpenResult(userId: user.id) })
                            .contextMenu {
                                Button {
                                    Task { await viewModel.refine(.moreLike(userId: user.id), mode: appState.currentMode) }
                                } label: {
                                    Label(String(format: bundle.loc("More like %@"), user.name),
                                          systemImage: "person.2")
                                }
                                Button(role: .destructive) {
                                    withAnimation { viewModel.notAFit(userId: user.id) }
                                } label: {
                                    Label(bundle.loc("Not a fit"), systemImage: "hand.thumbsdown")
                                }
                            }
                    } else if appState.currentMode == .hobby {
                        FriendSearchCard(user: user)
                    } else {
                        ColleagueSearchCard(user: user)
                    }
                }
                .onAppear {
                    // Last row appearing → fetch the next page
                    // (loadMore itself no-ops mid-AI-search).
                    if user.id == viewModel.results.last?.id {
                        Task { await viewModel.loadMore(mode: appState.currentMode) }
                    }
                }
            }
            if viewModel.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var postResults: some View {
        if trimmedText.isEmpty && !showsAIResults {
            searchHint(aiEnabled
                       ? bundle.loc("Describe the posts you want to find, then tap Search.")
                       : bundle.loc("Type a word or #tag to find posts."))
        } else if viewModel.postResults.isEmpty && !viewModel.isLoading {
            if viewModel.aiSearchFailed {
                kujiraRetryState
            } else if !explainsEmptyResult {
                emptyKeywordState
            }
        } else {
            resultCount(viewModel.postResults.count)
            ForEach(viewModel.postResults) { post in
                VStack(alignment: .leading, spacing: 6) {
                    if let score = viewModel.postMatchScores[post.id] {
                        matchPill(score)
                    }
                    PostCard(
                        post: post,
                        onPostDeleted: { viewModel.removePost(id: post.id) },
                        onOpenDetail: { focus in
                            detailRoute = PostRoute(postId: post.id, focusComposer: focus)
                        }
                    )
                    .cardStyle()
                }
                .onAppear {
                    if post.id == viewModel.postResults.last?.id {
                        Task { await viewModel.loadMore(mode: appState.currentMode) }
                    }
                }
            }
            if viewModel.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func resultCount(_ count: Int) -> some View {
        Text(String(format: bundle.loc("%d results"), count))
            .scaledFont(13)
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    /// "72% match" above an AI post result. The same number the server
    /// ranked by, so the order and the percentages always agree.
    private func matchPill(_ score: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(String(format: bundle.loc("%d%% match"), Int((score * 100).rounded())))
        }
        .scaledFont(12, .semibold)
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
        .padding(.leading, 4)
    }

    private func searchHint(_ text: String) -> some View {
        Text(text)
            .scaledFont(14)
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 48)
    }

    private var emptyKeywordState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .scaledFont(36)
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("No results found", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: Refine an AI people search (AI_SEARCH_REVIEW.md, phase S4)

    private var refineBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let top = viewModel.results.first {
                        refineChip(String(format: bundle.loc("More like %@"), top.name), icon: "person.2") {
                            await viewModel.refine(.moreLike(userId: top.id), mode: appState.currentMode)
                        }
                    }
                    refineChip(bundle.loc("Closer to me"), icon: "location") {
                        await viewModel.refine(.closer, mode: appState.currentMode)
                    }
                    Button {
                        refineText = ""
                        showsRefinePrompt = true
                    } label: {
                        chipLabel(bundle.loc("Refine…"), icon: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    if viewModel.isRefining {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)
            }
            .disabled(viewModel.isRefining)
            if let message = viewModel.refineError {
                Text(message)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 4)
        .task(id: viewModel.searchSessionId) {
            await viewModel.loadFitReasons(lang: appState.appLanguage.rawValue)
        }
        .alert(bundle.loc("Refine your search"), isPresented: $showsRefinePrompt) {
            TextField(bundle.loc("e.g. only in Hanoi, into film cameras"), text: $refineText)
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Search")) {
                let text = refineText
                Task { await viewModel.refine(.text(text), mode: appState.currentMode) }
            }
        } message: {
            Text("Say what to change. Your search stays as it is.", bundle: bundle)
        }
    }

    private func refineChip(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            chipLabel(title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
        }
        .scaledFont(13, .medium)
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
    }

    // MARK: Trending prompts (AI on, empty field)

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .scaledFont(12)
                    .foregroundColor(themeManager.theme.primary)
                Text("Trending", bundle: bundle)
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            ForEach(viewModel.suggestions.prefix(4), id: \.self) { suggestion in
                Button {
                    isResettingSearch = true
                    searchText = suggestion
                    runAI()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .scaledFont(12)
                            .foregroundColor(themeManager.theme.primary)
                        Text(suggestion)
                            .scaledFont(14)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.theme.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func aiKeywordsBadge(_ criteria: AISearchCriteriaDTO) -> some View {
        // Gather all keywords from criteria
        let keywords: [(label: String, values: [String])] = [
            (bundle.loc("Interests"),  criteria.interests),
            (bundle.loc("Skills"),   criteria.skills),
            (bundle.loc("Keywords"),   criteria.bio_keywords + criteria.job_title_keywords),
            (bundle.loc("Location"),  criteria.location.map { [$0] } ?? []),
        ].filter { !$0.values.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .scaledFont(12, .semibold)
                Text("AI search keywords", bundle: bundle)
                    .scaledFont(12, .semibold)
            }
            .foregroundColor(themeManager.theme.primary)

            // Keyword rows
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keywords, id: \.label) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(row.label):")
                            .scaledFont(12, .medium)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .frame(width: 64, alignment: .leading)

                        // Chips
                        FlowLayout(spacing: 4) {
                            ForEach(row.values.prefix(5), id: \.self) { kw in
                                Text(kw)
                                    .scaledFont(12, .medium)
                                    .foregroundColor(themeManager.theme.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.theme.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Entity alias suggestions ("did you mean …?")

    private var entitySuggestionsBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.entitySuggestions) { suggestion in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .scaledFont(12, .semibold)
                        Text(String(format: bundle.loc("By \"%@\", did you mean?"), suggestion.keyword))
                            .scaledFont(12, .semibold)
                    }
                    .foregroundColor(themeManager.theme.primary)

                    FlowLayout(spacing: 6) {
                        ForEach(suggestion.candidates) { candidate in
                            Button {
                                Task { await viewModel.confirmAlias(keyword: suggestion.keyword, candidate: candidate) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(candidate.canonical_name)
                                        .scaledFont(12, .medium)
                                    Image(systemName: "plus.circle.fill")
                                        .scaledFont(11)
                                }
                                .foregroundColor(themeManager.theme.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.theme.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Search Warnings

    /// Renders only concrete "I couldn't understand / couldn't apply this" notices.
    /// Text is localized here from the backend's stable `code`, so the same warning
    /// reads correctly in both EN and VI.
    private func warningText(_ warning: SearchWarningDTO) -> String? {
        switch warning.code {
        case "venue_unresolved":
            guard let place = warning.value, !place.isEmpty else { return nil }
            return String(format: bundle.loc("Couldn't tell which city \"%@\" is in. Add a province to narrow it down."), place)
        case "query_unclear":
            return bundle.loc("Tell us what they're into, e.g. \"bạn nữ thích chụp ảnh film ở Hà Nội\".")
        case "no_match":
            return String(format: bundle.loc("No one here is into \"%@\" yet. Try a related interest or check the spelling."),
                          warning.value ?? "")
        case "no_match_together":
            return String(format: bundle.loc("No one is into all of these together: %@. Try fewer of them."),
                          warning.value ?? "")
        case "unsupported_trait":
            return bundle.loc("ConnectSphere doesn't search by height, weight or looks. Try interests, skills or a place.")
        default:
            return nil   // unknown code from a newer backend. Stay silent
        }
    }

    /// Warnings that say why nothing came back. They replace the generic
    /// empty state rather than sit on top of it.
    private var explainsEmptyResult: Bool {
        let codes: Set<String> = ["query_unclear", "no_match", "no_match_together", "unsupported_trait"]
        return viewModel.searchWarnings.contains { codes.contains($0.code) }
    }

    /// The one unresolved place in this batch, if any, it's what the clarify
    /// field teaches the app about.
    private var unresolvedPlace: String? {
        viewModel.searchWarnings
            .first { $0.code == "venue_unresolved" && !($0.value ?? "").isEmpty }?
            .value
    }

    private func searchWarningsBox(_ warnings: [SearchWarningDTO]) -> some View {
        let messages = warnings.compactMap(warningText)
        return Group {
            if !messages.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(13, .semibold)
                        .foregroundColor(AppColors.warning(colorScheme))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages, id: \.self) { message in
                            Text(message)
                                .scaledFont(13)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Teach-the-app row: only for a place we couldn't locate,
                        // and only while it's still worth asking.
                        if let place = unresolvedPlace {
                            if viewModel.clarifyUnconfirmed {
                                Text("Thanks, we couldn't confirm that one either, so it's been flagged for review.", bundle: bundle)
                                    .scaledFont(12)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                clarifyRow(for: place)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.warning(colorScheme).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    private func clarifyRow(for place: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: bundle.loc("What is \"%@\"?"), place))
                .scaledFont(12, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))

            HStack(alignment: .top, spacing: 8) {
                LocationSearchField(bundle.loc("e.g. Landmark 81"), text: $clarifyText) { field in
                    field
                        .scaledFont(13)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(AppColors.surface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .onSubmit { submitClarification(for: place) }

                Button { submitClarification(for: place) } label: {
                    if viewModel.isClarifying {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("Search again", bundle: bundle)
                            .scaledFont(12, .semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(themeManager.theme.primary))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isClarifying ||
                          clarifyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitClarification(for place: String) {
        let answer = clarifyText
        clarifyText = ""
        Task { await viewModel.clarifyLocation(alias: place, canonical: answer) }
    }

    private var kujiraEmptyState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .scaledFont(48)
            VStack(spacing: 6) {
                Text("Your request is truly unique!", bundle: bundle)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Kujira couldn't find anyone matching your description... What a shame! But at least Kujira has you here~ 💕", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // Network/server error while loading the list, don't keep the old list, let the user retry
    private var networkErrorState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .scaledFont(48)
            VStack(spacing: 6) {
                Text("Couldn't load results", bundle: bundle)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Check your connection and try again", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Button {
                Task { await viewModel.loadAll(mode: appState.currentMode) }
            } label: {
                Text("Retry", bundle: bundle)
                    .scaledFont(14, .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(themeManager.theme.primary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var kujiraRetryState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .scaledFont(48)
            VStack(spacing: 6) {
                Text("Kujira ran into a problem!", bundle: bundle)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Maybe the network is weak or Kujira is busy~ Try again later! 🙏", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Friend Search Card

struct FriendSearchCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    let user: UserProfile
    /// Shown beside the name when set (People you may know).
    var matchPercent: Int? = nil
    /// Shared with the card's button, so a pending request can move Accept /
    /// Decline to their own row instead of squeezing the name and bio.
    @State private var connect = ConnectViewModel()

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(user: user, size: 52)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(user.name)
                                    .scaledFont(16, .semibold)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                    .lineLimit(2)
                                if let matchPercent { MatchPercentBadge(percent: matchPercent) }
                            }
                            Text(user.bio)
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if let location = user.location {
                                HStack(spacing: 3) {
                                    Image(systemName: "mappin.circle.fill").scaledFont(11)
                                    Text(location).scaledFont(12).lineLimit(1)
                                    if let km = user.distanceKm {
                                        Text(String(format: bundle.loc("· ~%d km"), km)).scaledFont(12).lineLimit(1)
                                    }
                                }
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }

                        Spacer(minLength: 8)

                        // No connections to or from the official account.
                        if connect.status != .pendingReceived && !user.isOfficial
                            && !(appState.currentUser?.isOfficial ?? false) {
                            ConnectButton(targetUserId: user.id, sharedVM: connect)
                                .environment(appState)
                        }
                    }

                    if connect.status == .pendingReceived {
                        ConnectButton(targetUserId: user.id, fullWidth: true, sharedVM: connect)
                            .environment(appState)
                    }

                    if !user.interests.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(user.interests, id: \.self) { interest in
                                    Text(InterestNames.shared.displayName(interest, in: bundle))
                                        .scaledFont(11, .medium)
                                        .foregroundColor(themeManager.theme.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
                                }
                            }
                        }
                        .task { await InterestNames.shared.loadIfNeeded() }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").scaledFont(11)
                        Text(String(format: bundle.loc("%d mutual friends"), user.mutualCount)).scaledFont(12)
                    }
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(14)

            }
            .background(AppColors.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Colleague Search Card

struct ColleagueSearchCard: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    let user: UserProfile
    /// Shown beside the name when set (People you may know).
    var matchPercent: Int? = nil
    /// Shared with the card's button, so a pending request can move Accept /
    /// Decline to their own row instead of squeezing the name and bio.
    @State private var connect = ConnectViewModel()

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AvatarView(user: user, size: 52)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(user.name)
                                    .scaledFont(16, .semibold)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                    .lineLimit(2)
                                if let matchPercent { MatchPercentBadge(percent: matchPercent) }
                            }
                            if appState.currentMode == .work, let title = user.jobTitle, let company = user.company {
                                Text("\(title) · \(company)")
                                    .scaledFont(13, .medium)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .lineLimit(2)
                            }
                            if let location = user.location {
                                HStack(spacing: 3) {
                                    Image(systemName: "mappin.circle.fill").scaledFont(11)
                                    Text(location).scaledFont(12).lineLimit(1)
                                    if let km = user.distanceKm {
                                        Text(String(format: bundle.loc("· ~%d km"), km)).scaledFont(12).lineLimit(1)
                                    }
                                }
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }

                        Spacer(minLength: 8)

                        // No connections to or from the official account.
                        if connect.status != .pendingReceived && !user.isOfficial
                            && !(appState.currentUser?.isOfficial ?? false) {
                            ConnectButton(targetUserId: user.id, sharedVM: connect)
                                .environment(appState)
                        }
                    }

                    if connect.status == .pendingReceived {
                        ConnectButton(targetUserId: user.id, fullWidth: true, sharedVM: connect)
                            .environment(appState)
                    }

                    if !user.skills.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(user.skills.prefix(4), id: \.self) { skill in
                                    Text(skill)
                                        .scaledFont(11, .medium)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.base(colorScheme)))
                                }
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").scaledFont(11)
                        Text(String(format: bundle.loc("%d mutual connections"), user.mutualCount)).scaledFont(12)
                    }
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                .padding(14)

            }
            .background(AppColors.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
