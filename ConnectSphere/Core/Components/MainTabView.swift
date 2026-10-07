import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(UndoToastPresenter.self) var toastPresenter
    @Environment(FloatingChatPresenter.self) var floatingChatPresenter
    @State private var selectedTab = 0
    @State private var profileNavPath = NavigationPath()
    @State private var searchNavPath = NavigationPath()
    @State private var communityNavPath = NavigationPath()
    /// Owned here rather than by the assistant sheet: `.sheet` destroys its
    /// content on dismiss, so a view model created inside it would lose the
    /// conversation every time — including when "Take me there" dismisses.
    /// Injected into the environment for `ConversationListView` to present.
    @State private var assistantViewModel: AssistantViewModel?

    @State private var notificationBadge = NotificationBadgeViewModel()
    @State private var tabBarVisibility = AppTabBarVisibility()

    // Custom binding: TabView always calls the setter when a tab is tapped, even when
    // re-tapping the tab that's already active (the setter runs even if the value doesn't
    // change) — whereas onChange only fires when the value actually changes. This lets us
    // catch the "re-tap the active tab" event to reset the view, the same way the "Profile"
    // tab always shows a fresh view.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                let isReselect = newValue == selectedTab
                selectedTab = newValue
                if isReselect { resetTabState(newValue) }
            }
        )
    }

    var body: some View {
        @Bindable var appState = appState
        @Bindable var floatingChatPresenter = floatingChatPresenter
        return Group {
            if #available(iOS 26.0, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
        // First switch to a mode without a persona set up yet → show the persona creation form
        .sheet(item: $appState.pendingPersonaMode) { mode in
            PersonaSetupView(mode: mode)
                .environment(appState)
                .environment(themeManager)
        }
        // Undo toast for post soft-deletes (comment deletes use their own local
        // presenter inside CommentSheet, which is presented modally above this).
        .undoToastOverlay(toastPresenter)
        // Floating "chat head" mini windows — persist above every tab the
        // same way the undo toast does (see `FloatingChatPresenter.swift`).
        .floatingChatOverlay(floatingChatPresenter)
        // Double-tap on a bubble restores it here, regardless of which tab is
        // active — a root-level presentation sidesteps needing to replay
        // "switch tab → push Messages → push this conversation" navigation.
        .fullScreenCover(item: $floatingChatPresenter.restoringBubble) { bubble in
            NavigationStack {
                ChatView(
                    conversationId: bubble.id,
                    peer: bubble.peer,
                    otherUserLocation: bubble.otherUserLocation,
                    currentUserId: bubble.currentUserId,
                    token: bubble.token,
                    existingViewModel: bubble.viewModel
                )
            }
            .environment(appState)
            .environment(themeManager)
            .environment(floatingChatPresenter)
        }
        .accentColor(themeManager.theme.primary)
        // Dense feed/chat layouts have fixed-height controls — support Dynamic
        // Type up to a cap rather than unbounded accessibility sizes.
        .cappedDynamicType()
        .environment(assistantViewModel)
        .task {
            if assistantViewModel == nil {
                assistantViewModel = AssistantViewModel(appState: appState)
            }
            await notificationBadge.refresh(appState: appState)
            notificationBadge.startRealtime(appState: appState)
            consumePendingDeepLink()
            consumePendingAssistantNavigation()
        }
        .onChange(of: selectedTab) { _, newTab in
            resetTabState(newTab)
        }
        // Warm launch: link tapped while MainTabView is already showing — the `.task` above
        // only runs once on appearance, so onChange is needed to catch subsequent times.
        .onChange(of: appState.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        // Same pattern for assistant-driven navigation ("open Settings," "go
        // to Communities") — fires both while the assistant sheet is still
        // open (switches the tab underneath immediately) and again if
        // "Take me there" re-sets the same target after the sheet dismisses.
        .onChange(of: appState.pendingAssistantNavigation) { _, _ in
            consumePendingAssistantNavigation()
        }
        .onDisappear {
            WebSocketClient.shared.off("notification", tag: "mainTabBadge")
            WebSocketClient.shared.off("notification_count", tag: "mainTabBadge")
        }
    }

    /// iOS 26+: the system tab bar is hidden and `AppTabBar` draws a Liquid
    /// Glass pill with Home · Community · Notifications · Profile plus a
    /// separate round Search button — iOS keeps a `.search`-role tab inside the
    /// pill on iPhone, so the split has to be drawn ourselves.
    ///
    /// Tab *values* are unchanged from before the reorder, so everything that
    /// switches tabs by value (deep links, the assistant, `resetTabState`)
    /// still lands on the same screen.
    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: tabSelection) {
            Tab(value: 0) { FeedView(selectedTab: $selectedTab).toolbar(.hidden, for: .tabBar) }
            Tab(value: 2) { CommunitiesView(navPath: $communityNavPath).toolbar(.hidden, for: .tabBar) }
            Tab(value: 3) { NotificationsView().toolbar(.hidden, for: .tabBar) }
            Tab(value: 4) { ProfileView(navPath: $profileNavPath).toolbar(.hidden, for: .tabBar) }
            Tab(value: 1) { SearchView(navPath: $searchNavPath).toolbar(.hidden, for: .tabBar) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !tabBarVisibility.isHidden {
                AppTabBar(
                    selection: tabSelection,
                    items: [
                        .init(value: 0, icon: "house", selectedIcon: "house.fill", title: "Home"),
                        .init(value: 2, icon: "person.3", selectedIcon: "person.3.fill", title: "Community"),
                        .init(value: 3, icon: "bell", selectedIcon: "bell.fill", title: "Notifications",
                              badge: appState.notificationUnreadCount),
                        .init(value: 4, icon: "person", selectedIcon: "person.fill", title: "Profile"),
                    ],
                    searchValue: 1,
                    accent: themeManager.theme.primary)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: tabBarVisibility.isHidden)
        .environment(tabBarVisibility)
    }

    /// iOS < 26: same order and icon-only look as `modernTabs`.
    private var legacyTabs: some View {
        TabView(selection: tabSelection) {
            FeedView(selectedTab: $selectedTab)
                .tabItem { tabIcon(selectedTab == 0 ? "house.fill" : "house", "Home") }
                .tag(0)

            CommunitiesView(navPath: $communityNavPath)
                .tabItem { tabIcon(selectedTab == 2 ? "person.3.fill" : "person.3", "Community") }
                .tag(2)

            NotificationsView()
                .tabItem { tabIcon(selectedTab == 3 ? "bell.fill" : "bell", "Notifications") }
                .badge(appState.notificationUnreadCount > 0 ? appState.notificationUnreadCount : 0)
                .tag(3)

            ProfileView(navPath: $profileNavPath)
                .tabItem { tabIcon(selectedTab == 4 ? "person.fill" : "person", "Profile") }
                .tag(4)

            SearchView(navPath: $searchNavPath)
                .tabItem { tabIcon("magnifyingglass", "Search") }
                .tag(1)
        }
    }

    /// Icon-only tab label. The name lives on as the accessibility label so
    /// VoiceOver still says "Home" rather than the symbol's name.
    private func tabIcon(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text(title, bundle: bundle))
    }

    /// Resets tab state to its default — runs both when SWITCHING to this tab (onChange)
    /// and when RE-TAPPING the tab while it's already active (custom binding), for a
    /// consistent feel: re-tapping any tab behaves like opening it for the first time.
    private func resetTabState(_ tab: Int) {
        switch tab {
        case 1:
            searchNavPath = NavigationPath()
            appState.shouldResetSearch = true
        case 2:
            communityNavPath = NavigationPath()
        case 3:
            Task { await notificationBadge.refresh(appState: appState) }
        case 4:
            profileNavPath = NavigationPath()
        default:
            break
        }
    }

    /// Navigates to a community from a share link (`connectsphere://community/<id>`) —
    /// switches to the Community tab then pushes the id onto `communityNavPath`, using the
    /// same `navigationDestination(for: String.self)` mechanism that search results/Discover use
    /// (see `CommunitiesView.swift`). Clears `pendingDeepLink` so navigation doesn't repeat.
    private func consumePendingDeepLink() {
        guard case let .community(id)? = appState.pendingDeepLink else { return }
        appState.pendingDeepLink = nil
        selectedTab = 2
        // Same race as `pushProfilePath` below: `selectedTab = 2` triggers
        // `.onChange(of: selectedTab)` → `resetTabState(2)`, which resets
        // `communityNavPath` to root AFTER this function returns (SwiftUI
        // coalesces the state changes), silently wiping the push that
        // follows synchronously here. Defer it to the next run loop tick so
        // it lands after that reset instead of before it.
        Task { @MainActor in
            communityNavPath = NavigationPath()
            communityNavPath.append(id)
        }
    }

    /// Navigates based on a signal from the AI assistant ("go to Communities," "open
    /// Settings") — same consume-then-clear mechanism as `consumePendingDeepLink`.
    /// `.tab(n)` just switches tabs; `.settings` switches to the Profile tab then pushes
    /// `ProfileRoute.settings` onto `profileNavPath` (see `ProfileView`).
    private func consumePendingAssistantNavigation() {
        guard let target = appState.pendingAssistantNavigation else { return }
        appState.pendingAssistantNavigation = nil
        switch target {
        case .tab(let index):
            selectedTab = index
        case .settings:
            pushProfilePath([.settings])
        case .privacySecurity:
            pushProfilePath([.settings, .privacySecurity])
        case .blockedUsers:
            pushProfilePath([.settings, .privacySecurity, .blockedUsers])
        case .notificationSettings:
            pushProfilePath([.settings, .notificationSettings])
        case .changePassword:
            pushProfilePath([.settings, .privacySecurity])
            appState.pendingAssistantSheet = .changePassword
        case .deleteAccount:
            pushProfilePath([.settings, .privacySecurity])
            appState.pendingAssistantSheet = .deleteAccount
        case .editProfile:
            selectedTab = 4
            profileNavPath = NavigationPath()
            appState.pendingAssistantSheet = .editProfile
        }
    }

    /// Switches to the Profile tab and pushes a fresh sequence of routes onto
    /// its `NavigationPath`, so the back-stack the user lands on matches what
    /// a manual tap-through would have produced (e.g. `.changePassword`'s
    /// back button walks Privacy & Security → Settings → Profile).
    private func pushProfilePath(_ routes: [ProfileRoute]) {
        selectedTab = 4
        // Setting `selectedTab` above triggers `.onChange(of: selectedTab)` →
        // `resetTabState(4)`, which resets `profileNavPath` to root — SwiftUI
        // coalesces state changes into the next view-update pass, so that
        // reset actually runs AFTER this function returns, silently wiping
        // out a path pushed synchronously here (the real bug behind "Take me
        // there" landing on the bare Profile tab instead of the intended
        // screen). Defer the push to the next run loop tick so it lands
        // after that reset has already happened, not before it.
        Task { @MainActor in
            profileNavPath = NavigationPath()
            for route in routes { profileNavPath.append(route) }
        }
    }

}
