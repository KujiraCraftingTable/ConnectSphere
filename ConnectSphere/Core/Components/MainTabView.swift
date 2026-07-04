import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var selectedTab = 0
    @State private var communityUnreadCount = 0
    @State private var userNotifUnreadCount = 0
    @State private var profileNavPath = NavigationPath()

    private let userNotifRepo = UserNotificationRepository()

    var body: some View {
        TabView(selection: $selectedTab) {
            FeedView(selectedTab: $selectedTab)
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                    Text("Trang chủ", bundle: bundle)
                }
                .tag(0)

            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Tìm kiếm", bundle: bundle)
                }
                .tag(1)

            CommunitiesView()
                .tabItem {
                    Image(systemName: selectedTab == 2 ? "person.3.fill" : "person.3")
                    Text("Cộng đồng", bundle: bundle)
                }
                .badge(communityUnreadCount > 0 ? communityUnreadCount : 0)
                .tag(2)

            NotificationsView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "bell.fill" : "bell")
                    Text("Thông báo", bundle: bundle)
                }
                .badge(userNotifUnreadCount > 0 ? userNotifUnreadCount : 0)
                .tag(3)

            ProfileView(navPath: $profileNavPath)
                .tabItem {
                    Image(systemName: selectedTab == 4 ? "person.fill" : "person")
                    Text("Hồ sơ", bundle: bundle)
                }
                .tag(4)
        }
        .accentColor(themeManager.theme.primary)
        .task {
            await fetchUnreadCount()
            await fetchUserNotifCount()
            setupRealtimeBadges()
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 2 { Task { await fetchUnreadCount() } }
            if newTab == 3 { Task { await fetchUserNotifCount() } }
            if newTab == 4 { profileNavPath = NavigationPath() }
        }
        .onDisappear {
            WebSocketClient.shared.off("notification", tag: "mainTabBadge")
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
