import SwiftUI

/// The app's single search (the Search tab): people and posts, with an AI
/// toggle. Off — keyword search as you type, ranked by relevance on the
/// server. On — the prompt is broken down by the local LLM and results come
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
    @FocusState private var isFieldFocused: Bool
    @AppStorage("aiSearchEnabled") private var aiEnabled = false
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0

    /// Binding from MainTabView — resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    private var trimmedText: String { searchText.trimmingCharacters(in: .whitespaces) }
    private var showsAIResults: Bool { !viewModel.lastAIPrompt.isEmpty }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if aiEnabled && trimmedText.isEmpty && !showsAIResults && !viewModel.suggestions.isEmpty {
                        trendingSection
                    }

                    // Warning: parts of the prompt the AI didn't understand / couldn't apply.
                    // Only shown when there's an actual specific error — not a generic suggestion.
                    if !viewModel.searchWarnings.isEmpty {
                        searchWarningsBox(viewModel.searchWarnings)
                    }

                    // AI keywords box — visible after AI search, scrolls with content
                    if let criteria = viewModel.aiCriteria {
                        aiKeywordsBadge(criteria)
                    }

                    // Gray alias suggestion area — "did you mean …?" for the user to confirm
                    if !viewModel.entitySuggestions.isEmpty {
                        entitySuggestionsBox
                    }

                    LazyVStack(spacing: appState.currentMode == .hobby ? 10 : 8) {
                        if viewModel.isLoading && !showsAIResults {
                            ProgressView().padding(.top, 40)
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
            .safeAreaInset(edge: .top, spacing: 0) { searchHeader }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Search"))
            // Large, like the Notifications tab's title.
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(AppColors.base(colorScheme), for: .navigationBar)
            .overlay {
                // The Kujira loading scene, shown while an AI search runs.
                if viewModel.isLoading && showsAIResults {
                    AISearchLoadingView()
                        .environment(appState)
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
            }
            .onChange(of: searchText) { _, query in
                if isResettingSearch { isResettingSearch = false; return }
                // AI runs on submit, not per keystroke — but clearing the field
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
            .onChange(of: appState.currentMode) { _, _ in rerunInCurrentScope() }
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
                // Only load on the first pass — avoids resetting AI results when backing out of a profile via swipe/back button
                guard viewModel.results.isEmpty, viewModel.postResults.isEmpty else { return }
                await viewModel.loadAll(mode: appState.currentMode)
            }
        }
    }

    // MARK: Header — field, AI toggle, scope

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: aiEnabled ? "sparkles" : "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(aiEnabled ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
                    TextField("", text: $searchText, prompt: Text(placeholder))
                        .font(.system(size: 15))
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
                .background(AppColors.elevated(colorScheme), in: Capsule())
                .overlay(
                    Capsule().stroke(aiEnabled ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                                     lineWidth: aiEnabled ? 1.5 : 1)
                )

                aiToggle
            }

            Picker("", selection: Bindable(viewModel).scope) {
                Text("People", bundle: bundle).tag(SearchScope.people)
                Text("Posts", bundle: bundle).tag(SearchScope.posts)
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
        .background(AppColors.base(colorScheme), ignoresSafeAreaEdges: [])
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
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(aiEnabled ? .white : AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(aiEnabled ? AnyShapeStyle(themeManager.theme.primary) : AnyShapeStyle(AppColors.elevated(colorScheme)),
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
        return appState.currentMode == .hobby
            ? bundle.loc("Search by name, interests, location...")
            : bundle.loc("Search by name, skills, company...")
    }

    // MARK: Actions

    private func runAI() {
        guard aiEnabled, !trimmedText.isEmpty else { return }
        isFieldFocused = false
        let radius = searchRadiusKm > 0 ? searchRadiusKm : nil
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

    private func resetToBrowse() {
        isResettingSearch = !searchText.isEmpty
        searchText = ""
        isFieldFocused = false
        viewModel.scope = .people
        viewModel.currentUserId = appState.currentUser?.id
        Task { await viewModel.loadAll(mode: appState.currentMode) }
    }

    // MARK: Results

    @ViewBuilder
    private var peopleResults: some View {
        // lastAIPrompt marks "an AI search has run" — gated on having results
        // so this doesn't collide with the empty/retry states below.
        if !trimmedText.isEmpty && !viewModel.results.isEmpty {
            resultCount(viewModel.results.count)
        }
        if viewModel.results.isEmpty && showsAIResults && !viewModel.isLoading {
            if viewModel.aiSearchFailed {
                kujiraRetryState
            } else {
                kujiraEmptyState
            }
        } else if viewModel.results.isEmpty && !trimmedText.isEmpty && !viewModel.isLoading {
            emptyKeywordState
        } else {
            ForEach(viewModel.results) { user in
                Group {
                    // AI search results → mini CV with match reasons; regular search keeps the old card
                    if showsAIResults {
                        MiniCVCard(user: user, evidence: viewModel.matchEvidence[user.id] ?? [])
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
            } else {
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
            .font(.system(size: 13))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    /// "72% match" above an AI post result — the same number the server
    /// ranked by, so the order and the percentages always agree.
    private func matchPill(_ score: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(String(format: bundle.loc("%d%% match"), Int((score * 100).rounded())))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
        .padding(.leading, 4)
    }

    private func searchHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 48)
    }

    private var emptyKeywordState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("No results found", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: Trending prompts (AI on, empty field)

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.theme.primary)
                Text("Trending", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
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
                            .font(.system(size: 12))
                            .foregroundColor(themeManager.theme.primary)
                        Text(suggestion)
                            .font(.system(size: 14))
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
                    .font(.system(size: 12, weight: .semibold))
                Text("AI search keywords", bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(themeManager.theme.primary)

            // Keyword rows
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keywords, id: \.label) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(row.label):")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .frame(width: 64, alignment: .leading)

                        // Chips
                        FlowLayout(spacing: 4) {
                            ForEach(row.values.prefix(5), id: \.self) { kw in
                                Text(kw)
                                    .font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(format: bundle.loc("By \"%@\", did you mean?"), suggestion.keyword))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(themeManager.theme.primary)

                    FlowLayout(spacing: 6) {
                        ForEach(suggestion.candidates) { candidate in
                            Button {
                                Task { await viewModel.confirmAlias(keyword: suggestion.keyword, candidate: candidate) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(candidate.canonical_name)
                                        .font(.system(size: 12, weight: .medium))
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 11))
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
            return String(format: bundle.loc("Couldn't tell which city \"%@\" is in — add a province to narrow it down."), place)
        case "query_unclear":
            return bundle.loc("Couldn't pick out anything specific to search for — try naming an interest, skill, or place.")
        default:
            return nil   // unknown code from a newer backend — stay silent
        }
    }

    /// The one unresolved place in this batch, if any — it's what the clarify
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.warning(colorScheme))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages, id: \.self) { message in
                            Text(message)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Teach-the-app row: only for a place we couldn't locate,
                        // and only while it's still worth asking.
                        if let place = unresolvedPlace {
                            if viewModel.clarifyUnconfirmed {
                                Text("Thanks — we couldn't confirm that one either, so it's been flagged for review.", bundle: bundle)
                                    .font(.system(size: 12))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))

            HStack(spacing: 8) {
                TextField(bundle.loc("e.g. Landmark 81"), text: $clarifyText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AppColors.surface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit { submitClarification(for: place) }

                Button { submitClarification(for: place) } label: {
                    if viewModel.isClarifying {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("Search again", bundle: bundle)
                            .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 48))
            VStack(spacing: 6) {
                Text("Your request is truly unique!", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Kujira couldn't find anyone matching your description... What a shame! But at least Kujira has you here~ 💕", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // Network/server error while loading the list — don't keep the old list, let the user retry
    private var networkErrorState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .font(.system(size: 48))
            VStack(spacing: 6) {
                Text("Couldn't load results", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Check your connection and try again", bundle: bundle)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Button {
                Task { await viewModel.loadAll(mode: appState.currentMode) }
            } label: {
                Text("Retry", bundle: bundle)
                    .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 48))
            VStack(spacing: 6) {
                Text("Kujira ran into a problem!", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Maybe the network is weak or Kujira is busy~ Try again later! 🙏", bundle: bundle)
                    .font(.system(size: 13))
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
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                if let matchPercent { MatchPercentBadge(percent: matchPercent) }
                            }
                            Text(user.bio)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            if let location = user.location {
                                HStack(spacing: 3) {
                                    Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                                    Text(location).font(.system(size: 12))
                                }
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }

                        Spacer()

                        ConnectButton(targetUserId: user.id)
                            .environment(appState)
                    }

                    if !user.interests.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(user.interests, id: \.self) { interest in
                                    Text(interest)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(themeManager.theme.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
                                }
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 11))
                        Text(String(format: bundle.loc("%d mutual friends"), user.mutualCount)).font(.system(size: 12))
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
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                if let matchPercent { MatchPercentBadge(percent: matchPercent) }
                            }
                            if let title = user.jobTitle, let company = user.company {
                                Text("\(title) · \(company)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            if let location = user.location {
                                HStack(spacing: 3) {
                                    Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                                    Text(location).font(.system(size: 12))
                                }
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }

                        Spacer()

                        ConnectButton(targetUserId: user.id)
                            .environment(appState)
                    }

                    if !user.skills.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(user.skills.prefix(4), id: \.self) { skill in
                                    Text(skill)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.base(colorScheme)))
                                }
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 11))
                        Text(String(format: bundle.loc("%d mutual connections"), user.mutualCount)).font(.system(size: 12))
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
