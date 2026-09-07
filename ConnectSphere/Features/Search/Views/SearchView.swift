import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = SearchViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText = ""
    /// What the user types when telling us what an unrecognized place actually is.
    @State private var clarifyText = ""
    @State private var showAISearch = false
    @State private var isSearchPresented = false
    @State private var isResettingSearch = false

    /// Binding from MainTabView — resets to root whenever the tab is re-selected
    @Binding var navPath: NavigationPath

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // AI Search banner — scrolls with content
                    aiSearchBanner
                        .onTapGesture { showAISearch = true }
                    Divider()

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
                        if viewModel.isLoading {
                            ProgressView().padding(.top, 40)
                        } else if viewModel.error != nil {
                            networkErrorState
                        } else {
                            // lastAIPrompt marks "an AI search has run" — gated on
                            // having results so this doesn't collide with the
                            // empty/retry states below.
                            if !searchText.isEmpty || (!viewModel.lastAIPrompt.isEmpty && !viewModel.results.isEmpty) {
                                Text(String(format: bundle.loc("%d results"), viewModel.results.count))
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                            }
                            if viewModel.results.isEmpty && !viewModel.lastAIPrompt.isEmpty {
                                if viewModel.aiSearchFailed {
                                    kujiraRetryState
                                } else {
                                    kujiraEmptyState
                                }
                            } else {
                                ForEach(viewModel.results) { user in
                                    // AI search results → mini CV with match reasons; regular search keeps the old card
                                    if !viewModel.lastAIPrompt.isEmpty {
                                        MiniCVCard(user: user, evidence: viewModel.matchEvidence[user.id] ?? [])
                                    } else if appState.currentMode == .hobby {
                                        FriendSearchCard(user: user)
                                    } else {
                                        ColleagueSearchCard(user: user)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
            }
            .background(AppColors.base(colorScheme))
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Search"))
            .toolbarBackground(AppColors.base(colorScheme), for: .navigationBar)
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: appState.currentMode == .hobby
                    ? bundle.loc("Search by name, interests, location...")
                    : bundle.loc("Search by name, skills, company...")
            )
            .onChange(of: appState.shouldFocusSearch) { _, newValue in
                if newValue {
                    isSearchPresented = true
                    appState.shouldFocusSearch = false
                }
            }
            .onChange(of: appState.shouldResetSearch) { _, newValue in
                // Re-tapping the "Search" tab while already active → return to the default
                // browse state, clearing all accumulated search/AI search state
                guard newValue else { return }
                isResettingSearch = true   // prevent onChange(searchText) from triggering a redundant search()
                searchText = ""
                isSearchPresented = false
                Task { await viewModel.loadAll(mode: appState.currentMode) }
                appState.shouldResetSearch = false
            }
            .onChange(of: searchText) { query in
                // Skip if this is a programmatic clear right after AI search
                if isResettingSearch { isResettingSearch = false; return }
                guard query != viewModel.lastAIPrompt else { return }
                viewModel.search(query: query, mode: appState.currentMode)
            }
            .onChange(of: appState.currentMode) { mode in
                Task { await viewModel.loadAll(mode: mode) }
            }
            .onChange(of: showAISearch) { isPresented in
                // When the sheet closes after an AI search → clear the search bar (without triggering a regular search)
                if !isPresented && !viewModel.lastAIPrompt.isEmpty {
                    isResettingSearch = true
                    searchText = ""
                }
            }
            .task {
                // .task re-runs when the view "reappears" (e.g. popping back from a pushed profile).
                // If this is because the Search tab was re-tapped (shouldResetSearch = true) →
                // reset fully right here rather than waiting on onChange (which could be missed
                // because the view is covered by the pushed profile when the flag was set).
                if appState.shouldResetSearch {
                    appState.shouldResetSearch = false
                    isResettingSearch = true
                    searchText = ""
                    isSearchPresented = false
                    viewModel.currentUserId = appState.currentUser?.id
                    await viewModel.loadAll(mode: appState.currentMode)
                    return
                }
                // Only load on the first pass — avoids resetting AI results when backing out of a profile via swipe/back button
                guard viewModel.results.isEmpty else { return }
                viewModel.currentUserId = appState.currentUser?.id
                await viewModel.loadAll(mode: appState.currentMode)
            }
            .sheet(isPresented: $showAISearch) {
                AISearchSheet(viewModel: viewModel)
                    .environment(appState)
            }
        }
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
                        .foregroundColor(.orange)
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
                .background(Color.orange.opacity(0.10))
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

    // MARK: AI Search Banner

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

    private var aiSearchBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.primary.opacity(0.12))
                    .frame(width: 44, height: 44)
                Text("🐳")
                    .font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Kujira")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(viewModel.lastAIPrompt.isEmpty
                    ? bundle.loc("Let Kujira help you search more effectively~")
                    : bundle.loc("I just helped you search~\nAlways here for you! 💕"))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .padding(14)
        .background(AppColors.surface(colorScheme))
    }
}

// MARK: - AI Search Sheet

struct AISearchSheet: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    var viewModel: SearchViewModel
    @State private var prompt = ""
    @FocusState private var isPromptFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0

    // Pre-fill with last AI prompt so user can refine it
    private var initialPrompt: String { viewModel.lastAIPrompt }

    private var isPromptEmpty: Bool { prompt.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Hero header — mascot Kujira + greeting

    private var heroHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.primary.opacity(0.12))
                    .frame(width: 76, height: 76)
                Text("🐳").font(.system(size: 40))
            }
            Text("Let Kujira help you search more effectively~", bundle: bundle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: Description input field — background like a post card, moderate height, bright border when focused

    private var promptInput: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.surface(colorScheme))
            if prompt.isEmpty {
                Text("I want to find someone who likes jjk...", bundle: bundle)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(8)
                .focused($isPromptFocused)
        }
        .frame(minHeight: 120, maxHeight: 150)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isPromptFocused ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                        lineWidth: isPromptFocused ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { isPromptFocused = true }
        .animation(.easeInOut(duration: 0.15), value: isPromptFocused)
    }

    // MARK: Trending suggestions — tappable pills for quick-fill

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
                    prompt = suggestion
                    isPromptFocused = true
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
    }

    // MARK: Search button — pinned to the bottom, floats above the keyboard

    private var searchButtonBar: some View {
        Button {
            Task {
                let radius = searchRadiusKm > 0 ? searchRadiusKm : nil
                await viewModel.aiSearch(prompt: prompt, mode: appState.currentMode, radiusKm: radius)
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(viewModel.isLoading ? bundle.loc("Searching the high seas...") : bundle.loc("Search with Kujira"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isPromptEmpty ? AppColors.borderDefault(colorScheme) : themeManager.theme.primary,
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isPromptEmpty || viewModel.isLoading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.base(colorScheme))
    }

    var body: some View {
        NavigationStack {
            ZStack {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                promptInput
                if !viewModel.suggestions.isEmpty {
                    trendingSection
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(AppColors.base(colorScheme))
            .safeAreaInset(edge: .bottom) { searchButtonBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }

            // Loading overlay
            if viewModel.isLoading {
                AISearchLoadingView()
                    .environment(appState)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
            } // ZStack
        }
        .onAppear { if prompt.isEmpty { prompt = initialPrompt } }
    }
}

// MARK: - Friend Search Card

struct FriendSearchCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    let user: UserProfile

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(user: user, size: 52)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
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

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AvatarView(user: user, size: 52)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary(colorScheme))
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
