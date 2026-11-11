import SwiftUI

/// "..." › Manage community › Requests: posts waiting for approval and, in a
/// private community, people asking to join. Both in one place for staff.
struct CommunityRequestsView: View {
    enum Tab: Hashable { case posts, join }

    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle

    let communityId: String
    /// A public community has no join requests, so no Join tab.
    let showsJoin: Bool
    @State private var tab: Tab
    @State private var postCount: Int
    @State private var joinCount: Int

    /// Opens on the tab with something waiting (posts when both or neither),
    /// unless `initialTab` says where.
    init(communityId: String, showsJoin: Bool, postCount: Int = 0, joinCount: Int = 0, initialTab: Tab? = nil) {
        self.communityId = communityId
        self.showsJoin = showsJoin
        _postCount = State(initialValue: postCount)
        _joinCount = State(initialValue: joinCount)
        let start = initialTab ?? (postCount == 0 && joinCount > 0 ? .join : .posts)
        _tab = State(initialValue: showsJoin ? start : .posts)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsJoin {
                Picker("", selection: $tab) {
                    Text(label("Posts", postCount)).tag(Tab.posts)
                    Text(label("Join", joinCount)).tag(Tab.join)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            switch tab {
            case .posts: PendingPostsView(communityId: communityId) { postCount = $0 }
            case .join:  JoinRequestsView(communityId: communityId, token: appState.authToken ?? "") { joinCount = $0 }
            }
        }
        .appBackground()
        .navigationTitle(Text("Requests", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(_ title: String, _ count: Int) -> String {
        count > 0 ? "\(bundle.loc(title)) · \(count)" : bundle.loc(title)
    }
}
