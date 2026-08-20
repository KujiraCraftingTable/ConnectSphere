import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var selectedTab = 0
    @State private var communityUnreadCount = 0
    @State private var userNotifUnreadCount = 0
    @State private var profileNavPath = NavigationPath()
    @State private var searchNavPath = NavigationPath()
    @State private var communityNavPath = NavigationPath()

    private let userNotifRepo = UserNotificationRepository()

    // Binding tùy chỉnh: TabView luôn gọi setter khi bấm tab, kể cả bấm lại tab
    // đang active (setter chạy dù giá trị không đổi) — trong khi onChange chỉ
    // bắn khi giá trị thực sự thay đổi. Nhờ vậy bắt được sự kiện "bấm lại tab
    // đang active" để reset view, giống cách tab "Hồ sơ" luôn hiện view sạch.
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
        // Lần đầu switch sang mode chưa setup persona → form tạo danh tính riêng
        .sheet(item: $appState.pendingPersonaMode) { mode in
            PersonaSetupView(mode: mode)
                .environment(appState)
                .environment(themeManager)
        }
        .accentColor(themeManager.theme.primary)
        .task {
            await fetchUnreadCount()
            await fetchUserNotifCount()
            setupRealtimeBadges()
        }
        .onChange(of: selectedTab) { _, newTab in
            resetTabState(newTab)
        }
        .onDisappear {
            WebSocketClient.shared.off("notification", tag: "mainTabBadge")
        }
    }

    /// iOS 26+: Tab API mới với role .search — Liquid Glass tự tách tab Search
    /// thành nút tròn nổi riêng cạnh pill 4 tab còn lại (kiểu Telegram),
    /// không cần tự vẽ custom bottom bar.
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
            .badge(communityUnreadCount > 0 ? communityUnreadCount : 0)

            Tab(value: 3) {
                NotificationsView()
            } label: {
                Label { Text("Notifications", bundle: bundle) } icon: { Image(systemName: "bell") }
            }
            .badge(userNotifUnreadCount > 0 ? userNotifUnreadCount : 0)

            Tab(value: 4) {
                ProfileView(navPath: $profileNavPath)
            } label: {
                Label { Text("Profile", bundle: bundle) } icon: { Image(systemName: "person") }
            }

            // Đặt cuối để hệ thống tách thành nút search nổi bên phải pill;
            // SearchView đã tự bọc NavigationStack + .searchable bên trong
            Tab(value: 1, role: .search) {
                SearchView(navPath: $searchNavPath)
            }
        }
    }

    /// iOS < 26: giữ nguyên layout TabView 5 tab dàn đều như cũ
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
                .badge(communityUnreadCount > 0 ? communityUnreadCount : 0)
                .tag(2)

            NotificationsView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "bell.fill" : "bell")
                    Text("Notifications", bundle: bundle)
                }
                .badge(userNotifUnreadCount > 0 ? userNotifUnreadCount : 0)
                .tag(3)

            ProfileView(navPath: $profileNavPath)
                .tabItem {
                    Image(systemName: selectedTab == 4 ? "person.fill" : "person")
                    Text("Profile", bundle: bundle)
                }
                .tag(4)
        }
    }

    /// Reset trạng thái tab về mặc định — chạy khi CHUYỂN sang tab này (onChange)
    /// hoặc khi BẤM LẠI tab đang active (custom binding), cho cảm giác nhất quán:
    /// bấm lại tab nào cũng như mở tab đó lần đầu.
    private func resetTabState(_ tab: Int) {
        switch tab {
        case 1:
            searchNavPath = NavigationPath()
            appState.shouldResetSearch = true
        case 2:
            communityNavPath = NavigationPath()
            Task { await fetchUnreadCount() }
        case 3:
            Task { await fetchUserNotifCount() }
        case 4:
            profileNavPath = NavigationPath()
        default:
            break
        }
    }

    /// Kết nối socket và cập nhật badge ngay khi có notification mới
    /// (like/comment/kết nối) — không cần đợi user mở tab Thông báo.
    private func setupRealtimeBadges() {
        guard let token = appState.authToken else { return }
        WebSocketClient.shared.connect(token: token)
        WebSocketClient.shared.on("notification", tag: "mainTabBadge") { _ in
            Task { @MainActor in
                await fetchUserNotifCount()
            }
        }
    }

    private func fetchUserNotifCount() async {
        guard let token = appState.authToken else { return }
        if let response = try? await userNotifRepo.fetchAll(token: token) {
            userNotifUnreadCount = response.unread
        }
    }

    /// Poll unread community notification count to drive the tab badge
    private func fetchUnreadCount() async {
        guard let token = appState.authToken else { return }
        do {
            let res = try await NetworkClient.shared.fetch(
                DataResponse<UnreadCountResponse>.self,
                path: "/notifications/unread-count",
                token: token
            )
            communityUnreadCount = res.data.count
        } catch {
            // Silent — badge is non-critical
        }
    }
}
