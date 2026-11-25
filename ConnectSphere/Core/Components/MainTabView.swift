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
    /// conversation every time. Including when "Take me there" dismisses.
    /// Injected into the environment for `ConversationListView` to present.
    @State private var assistantViewModel: AssistantViewModel?

    @State private var notificationBadge = NotificationBadgeViewModel()

    // Custom binding: TabView always calls the setter when a tab is tapped, even when
    // re-tapping the tab that's already active (the setter runs even if the value doesn't
    // change), whereas onChange only fires when the value actually changes. This lets us
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
        .undoToastOverlay(toastPresenter, bottomInset: 64)
        // Floating "chat head" mini windows, persist above every tab the
        // same way the undo toast does (see `FloatingChatPresenter.swift`).
        .floatingChatOverlay(floatingChatPresenter)
        // Double-tap on a bubble restores it here, regardless of which tab is
        // active, a root-level presentation sidesteps needing to replay
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
            .environment(toastPresenter)
        }
        .accentColor(themeManager.theme.primary)
        // Dense feed/chat layouts have fixed-height controls. Support Dynamic
        // Type up to a cap rather than unbounded accessibility sizes.
        .cappedDynamicType()
        .environment(assistantViewModel)
        .task {
            if assistantViewModel == nil {
                assistantViewModel = AssistantViewModel(appState: appState, themeManager: themeManager)
            }
            await notificationBadge.refresh(appState: appState)
            notificationBadge.startRealtime(appState: appState)
            consumePendingDeepLink()
            consumePendingAssistantNavigation()
        }
        // Leaving the Notifications tab clears its badge; the notifications stay unread.
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == 3 && newTab != 3 {
                Task { await notificationBadge.markSeen(appState: appState) }
            }
        }
        // The badge counts the mode you're in.
        .onChange(of: appState.currentMode) {
            Task { await notificationBadge.refresh(appState: appState) }
        }
        // Warm launch: link tapped while MainTabView is already showing. The `.task` above
        // only runs once on appearance, so onChange is needed to catch subsequent times.
        .onChange(of: appState.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        // Same pattern for assistant-driven navigation ("open Settings," "go
        // to Communities"), fires both while the assistant sheet is still
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

    /// iOS 26+: the system Liquid Glass tab bar, Home · Community ·
    /// Notifications · Profile in the pill, Search detached beside it.
    /// System `Tab(_:systemImage:)` labels (titles stay for VoiceOver;
    /// `.iconOnly` hides them on screen). `.labelStyle` is inherited, so each
    /// tab's content resets it to `.automatic`, otherwise every `Label`
    /// inside the app (a profile's location, a job's place) lost its text.
    ///
    /// Tab *values* are unchanged from before the reorder, so everything that
    /// switches tabs by value (deep links, the assistant, `resetTabState`)
    /// still lands on the same screen.
    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: tabSelection) {
            Tab(bundle.loc("Home"), systemImage: "house", value: 0) {
                FeedView(selectedTab: $selectedTab)
                    .labelStyle(.automatic)
            }
            // Work mode: Jobs takes Community's place (communities open from it).
            Tab(bundle.loc(appState.currentMode == .work ? "Jobs" : "Community"),
                systemImage: appState.currentMode == .work ? "briefcase" : "person.3", value: 2) {
                communityOrJobs
                    .labelStyle(.automatic)
            }
            Tab(bundle.loc("Notifications"), systemImage: "bell", value: 3) {
                NotificationsView()
                    .labelStyle(.automatic)
            }
            .badge(appState.notificationUnreadCount > 0 ? appState.notificationUnreadCount : 0)
            Tab(bundle.loc("Profile"), systemImage: "person", value: 4) {
                ProfileView(navPath: $profileNavPath)
                    .labelStyle(.automatic)
            }
            // The app's one search entry (people + posts); SearchView keeps
            // its own field and AI toggle inside its NavigationStack.
            Tab(bundle.loc("Search"), systemImage: "magnifyingglass", value: 1, role: searchTabRole) {
                SearchView(navPath: $searchNavPath)
                    .labelStyle(.automatic)
            }
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var communityOrJobs: some View {
        if appState.currentMode == .work {
            JobsHomeView()
        } else {
            CommunitiesView(navPath: $communityNavPath)
        }
    }

    /// Which role detaches Search into its own glass circle. iOS 26 detaches a
    /// `.search` tab by itself; from the iOS 27 SDK only the tab bar's
    /// *prominent* tab is detached, and a search tab is only made prominent
    /// when it auto-activates a system search field, which SearchView, with
    /// its own field, doesn't use. So on 27 it's marked prominent explicitly.
    @available(iOS 26.0, *)
    private var searchTabRole: TabRole {
        if #available(iOS 27.0, *) { return .prominent }
        return .search
    }

    /// iOS < 26: same order and icon-only look as `modernTabs`.
    private var legacyTabs: some View {
        TabView(selection: tabSelection) {
            FeedView(selectedTab: $selectedTab)
                .tabItem { tabIcon(selectedTab == 0 ? "house.fill" : "house", "Home") }
                .tag(0)

            communityOrJobs
                .tabItem {
                    appState.currentMode == .work
                        ? tabIcon(selectedTab == 2 ? "briefcase.fill" : "briefcase", "Jobs")
                        : tabIcon(selectedTab == 2 ? "person.3.fill" : "person.3", "Community")
                }
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

    /// Resets tab state to its default. Runs only when RE-TAPPING the tab while it's
    /// already active (custom binding): switching to a tab shows it as you left it.
    private func resetTabState(_ tab: Int) {
        switch tab {
        case 0:
            appState.shouldResetFeed = true
        case 1:
            searchNavPath = NavigationPath()
            appState.shouldResetSearch = true
        case 2:
            communityNavPath = NavigationPath()
            appState.communitiesReloadTick += 1
        case 3:
            Task { await notificationBadge.refresh(appState: appState) }
            appState.notificationsReloadTick += 1
        case 4:
            profileNavPath = NavigationPath()
        default:
            break
        }
    }

    /// Navigates to a community from a share link (`connectsphere://community/<id>`),
    /// switches to the Community tab then pushes the id onto `communityNavPath`, using the
    /// same `navigationDestination(for: String.self)` mechanism that search results/Discover use
    /// (see `CommunitiesView.swift`). Clears `pendingDeepLink` so navigation doesn't repeat.
    private func consumePendingDeepLink() {
        guard case let .community(id)? = appState.pendingDeepLink else { return }
        appState.pendingDeepLink = nil
        selectedTab = 2
        // Communities are Hobby-only; in Work mode that tab is Jobs.
        if appState.currentMode == .work { appState.requestModeSwitch(to: .hobby) }
        communityNavPath = NavigationPath()
        communityNavPath.append(id)
    }

    /// Navigates where the assistant pointed, same consume-then-clear
    /// mechanism as `consumePendingDeepLink`. A sheet or a row highlight is
    /// handed on to the screen that owns it, which opens or flashes it once
    /// it has appeared.
    private func consumePendingAssistantNavigation() {
        guard let target = appState.pendingAssistantNavigation else { return }
        appState.pendingAssistantNavigation = nil
        switch target {
        case .tab(let index):
            selectedTab = index
        case .profile(let routes, let sheet, let highlight):
            pushProfilePath(routes)
            appState.pendingAssistantSheet = sheet
            appState.assistantHighlight = highlight
        }
    }

    /// Switches to the Profile tab and pushes a fresh sequence of routes onto
    /// its `NavigationPath`, so the back-stack the user lands on matches what
    /// a manual tap-through would have produced (e.g. `.changePassword`'s
    /// back button walks Privacy & Security → Settings → Profile).
    private func pushProfilePath(_ routes: [ProfileRoute]) {
        selectedTab = 4
        profileNavPath = NavigationPath()
        for route in routes { profileNavPath.append(route) }
    }

}
