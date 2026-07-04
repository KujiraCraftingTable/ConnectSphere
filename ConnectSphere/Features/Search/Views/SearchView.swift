import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var viewModel = SearchViewModel()
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText = ""
    @State private var showAISearch = false
    @State private var isSearchPresented = false
    @State private var isResettingSearch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // AI Search banner — scrolls with content
                    aiSearchBanner
                        .onTapGesture { showAISearch = true }
                    Divider()

                    // AI tips box — ẩn khi Kujira empty state đang hiển thị
                    if !viewModel.aiTips.isEmpty && !(viewModel.results.isEmpty && !viewModel.lastAIPrompt.isEmpty) {
                        aiTipsBox(viewModel.aiTips)
                    }

                    // AI keywords box — visible after AI search, scrolls with content
                    if let criteria = viewModel.aiCriteria {
                        aiKeywordsBadge(criteria)
                    }

                    LazyVStack(spacing: appState.currentMode == .friend ? 10 : 8) {
                        if viewModel.isLoading {
                            ProgressView().padding(.top, 40)
                        } else {
                            if !searchText.isEmpty || !viewModel.aiReasoning.isEmpty {
                                Text(String(format: bundle.loc("%d kết quả"), viewModel.results.count))
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
                                    if appState.currentMode == .friend {
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
            .navigationTitle(bundle.loc("Tìm kiếm"))
            .toolbarBackground(AppColors.base(colorScheme), for: .navigationBar)
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: appState.currentMode == .friend
                    ? bundle.loc("Tìm theo tên, sở thích, địa điểm...")
                    : bundle.loc("Tìm theo tên, kỹ năng, công ty...")
            )
            .onChange(of: appState.shouldFocusSearch) { _, newValue in
                if newValue {
                    isSearchPresented = true
                    appState.shouldFocusSearch = false
                }
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
                // Khi sheet đóng sau AI search → clear search bar (không trigger regular search)
                if !isPresented && !viewModel.lastAIPrompt.isEmpty {
                    isResettingSearch = true
                    searchText = ""
                }
            }
            .task {
                // Chỉ load lần đầu — tránh reset AI results khi back từ profile
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
        // Gom tất cả keywords từ criteria
        let keywords: [(label: String, values: [String])] = [
            (bundle.loc("Sở thích"),  criteria.interests),
            (bundle.loc("Kỹ năng"),   criteria.skills),
            (bundle.loc("Từ khóa"),   criteria.bio_keywords + criteria.job_title_keywords),
            (bundle.loc("Địa điểm"),  criteria.location.map { [$0] } ?? []),
        ].filter { !$0.values.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text("Từ khoá AI đã tìm", bundle: bundle)
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

    // MARK: AI Tips Box

    private func aiTipsBox(_ tips: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
                .padding(.top, 1)
            Text(tips)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.theme.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: AI Search Banner

    private var kujiraEmptyState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .font(.system(size: 48))
            VStack(spacing: 6) {
                Text("Yêu cầu của bạn thật độc nhất luôn á!", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Kujira chưa tìm thấy ai có sở thích như bạn mô tả... Tiếc ghê! Nhưng ít nhất Kujira có bạn ở đây rồi~ 💕", bundle: bundle)
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

    private var kujiraRetryState: some View {
        VStack(spacing: 16) {
            Text("🐳")
                .font(.system(size: 48))
            VStack(spacing: 6) {
                Text("Kujira gặp chút sự cố rồi!", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                Text("Có thể do mạng yếu hoặc Kujira đang bận tý~ Bạn thử lại sau nhé! 🙏", bundle: bundle)
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
                    ? bundle.loc("Hãy để Kujira giúp bạn tìm hiệu quả hơn nha~")
                    : bundle.loc("Mình vừa giúp bạn tìm rồi á~ \nBạn mình luôn sẵn lòng giúp bạn! 💕"))
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("searchRadiusKm") private var searchRadiusKm: Int = 0

    // Pre-fill with last AI prompt so user can refine it
    private var initialPrompt: String { viewModel.lastAIPrompt }


    var body: some View {
        NavigationStack {
            ZStack {
            VStack(spacing: 0) {
                // Prompt input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nhập người bạn muốn tìm vào đây nhe", bundle: bundle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppColors.base(colorScheme))
                            .frame(minHeight: 100)
                        if prompt.isEmpty {
                            Text("Tui muốn tìm bạn thích xem jjk...", bundle: bundle)
                                .font(.system(size: 15))
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.6))
                                .padding(12)
                        }
                        TextEditor(text: $prompt)
                            .font(.system(size: 15))
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(8)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                }
                .padding(16)

                // Trending prompts
                if !viewModel.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12))
                                .foregroundColor(themeManager.theme.primary)
                            Text("Xu hướng", bundle: bundle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }

                        ForEach(viewModel.suggestions.prefix(4), id: \.self) { suggestion in
                            Button {
                                prompt = suggestion
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 12))
                                        .foregroundColor(themeManager.theme.primary)
                                    Text(suggestion)
                                        .font(.system(size: 14))
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                // Search button
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
                        Text(viewModel.isLoading ? bundle.loc("Đang trên đại hải trình...") : bundle.loc("Tìm cùng Kujira"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(prompt.trimmingCharacters(in: .whitespaces).isEmpty
                                ? AppColors.borderDefault(colorScheme) : themeManager.theme.primary,
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
                .padding(.horizontal, 16)

                Spacer()
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Bạn hỏi, Kujira trả lời"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Hủy")) { dismiss() }
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
                HStack(spacing: 12) {
                    AvatarView(user: user, size: 58)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(user.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Text(user.bio)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .lineLimit(1)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(user.interests.prefix(3), id: \.self) { interest in
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

                    Spacer()

                    Text("Kết nối", bundle: bundle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(themeManager.theme.primary, lineWidth: 1.5))
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
    @Environment(ThemeManager.self) var themeManager
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

                        Text("Kết nối", bundle: bundle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(themeManager.theme.primary))
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
                        Text(String(format: bundle.loc("%d kết nối chung"), user.followerCount % 15 + 1)).font(.system(size: 12))
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
