import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(UndoToastPresenter.self) var toastPresenter
    @State private var selectedTab = 0
    @State private var profileNavPath = NavigationPath()
    @State private var searchNavPath = NavigationPath()
    @State private var communityNavPath = NavigationPath()
    /// Owned here rather than by the assistant sheet: `.sheet` destroys its
    /// content on dismiss, so a view model created inside it would lose the
    /// conversation every time — including when "Take me there" dismisses.
    /// Injected into the environment for `ConversationListView` to present.
    @State private var assistantViewModel: AssistantViewModel?

    private let userNotifRepo = UserNotificationRepository()

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
        .accentColor(themeManager.theme.primary)
        // Dense feed/chat layouts have fixed-height controls — support Dynamic
        // Type up to a cap rather than unbounded accessibility sizes.
        .cappedDynamicType()
        .environment(assistantViewModel)
        .task {
            if assistantViewModel == nil {
                assistantViewModel = AssistantViewModel(appState: appState)
            }
            await fetchUserNotifCount()
            setupRealtimeBadges()
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

    /// iOS 26+: the new Tab API with role .search — Liquid Glass automatically splits the
    /// Search tab into its own floating round button next to the 4-tab pill (Telegram-style),
    /// no need to draw a custom bottom bar ourselves.
    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: tabSelection) {
            Tab(value: 0) {
                FeedView(selectedTab: $selectedTab)
            } label: {
                Label { Text("Home", bundle: bundle) } icon: { Image(systemName: "house") }
            }

            Tab(value: 2) {
                CommunitiesView(navPath: $communityNavPath)
            } label: {
                Label { Text("Community", bundle: bundle) } icon: { Image(systemName: "person.3") }
            }

            Tab(value: 3) {
                NotificationsView()
            } label: {
                Label { Text("Notifications", bundle: bundle) } icon: { Image(systemName: "bell") }
            }
            .badge(appState.notificationUnreadCount > 0 ? appState.notificationUnreadCount : 0)

            Tab(value: 4) {
                ProfileView(navPath: $profileNavPath)
            } label: {
                Label { Text("Profile", bundle: bundle) } icon: { Image(systemName: "person") }
            }

            // Placed last so the system splits it off into a floating search button to the
            // right of the pill; SearchView already wraps NavigationStack + .searchable internally
            Tab(value: 1, role: .search) {
                SearchView(navPath: $searchNavPath)
            }
        }
    }

    /// iOS < 26: keeps the original evenly-spaced 5-tab TabView layout
    private var legacyTabs: some View {
        TabView(selection: tabSelection) {
            FeedView(selectedTab: $selectedTab)
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                    Text("Home", bundle: bundle)
                }
                .tag(0)

            SearchView(navPath: $searchNavPath)
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search", bundle: bundle)
                }
                .tag(1)

            CommunitiesView(navPath: $communityNavPath)
                .tabItem {
                    Image(systemName: selectedTab == 2 ? "person.3.fill" : "person.3")
                    Text("Community", bundle: bundle)
                }
                .tag(2)

            NotificationsView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "bell.fill" : "bell")
                    Text("Notifications", bundle: bundle)
                }
                .badge(appState.notificationUnreadCount > 0 ? appState.notificationUnreadCount : 0)
                .tag(3)

            ProfileView(navPath: $profileNavPath)
                .tabItem {
                    Image(systemName: selectedTab == 4 ? "person.fill" : "person")
                    Text("Profile", bundle: bundle)
                }
                .tag(4)
        }
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
            Task { await fetchUserNotifCount() }
        case 4:
            profileNavPath = NavigationPath()
        default:
            break
        }
    }

    /// Connects the socket and updates the badge as soon as a new notification arrives
    /// (like/comment/connection) — no need to wait for the user to open the Notifications tab.
    private func setupRealtimeBadges() {
        guard let token = appState.authToken else { return }
        WebSocketClient.shared.connect(token: token)
        // The backend emits notification_count after every create/read/delete,
        // so the badge follows without refetching the list. `notification` is
        // still observed for older backends that only send that event.
        WebSocketClient.shared.on("notification_count", tag: "mainTabBadge") { _ in
            Task { @MainActor in await fetchUserNotifCount() }
        }
        WebSocketClient.shared.on("notification", tag: "mainTabBadge") { _ in
            Task { @MainActor in await fetchUserNotifCount() }
        }
    }

    private func fetchUserNotifCount() async {
        guard let token = appState.authToken else { return }
        if let count = try? await userNotifRepo.unreadCount(token: token) {
            appState.notificationUnreadCount = count
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
