import Foundation
import Observation

extension Notification.Name {
    /// The viewer's own communities changed (joined, left, pinned, edited),
    /// My communities reloads.
    static let communitiesChanged = Notification.Name("communitiesChanged")
}

@Observable
class CommunityDetailViewModel {
    var community: Community?
    var posts: [Post] = []
    var members: [CommunityMember] = []
    var isLoadingPosts = false
    var isLoadingMembers = false
    var errorMessage: String?
    var canLoadMorePosts = true
    var joinStatus: JoinStatus = .notMember

    private let communityId: String
    private let token: String
    private let currentUserId: String
    /// In the `community:<id>` room with live listeners registered.
    private var isInRoom = false
    private let repository = CommunityRepository()
    private let ws = WebSocketClient.shared
    private let pageSize = 20
    private var postOffset = 0
    /// Token for the `.webSocketDidReconnect` observer registered in `joinCommunityRoom()`;
    /// removed symmetrically in `leaveCommunityRoom()`. Mirrors `ChatViewModel`'s
    /// reconnect-handling exactly (see that file for why: server-side room
    /// membership doesn't survive a disconnect, but registered listeners do).
    private var reconnectObserver: NSObjectProtocol?
    /// Token for the `.postUpdated` observer registered in `joinCommunityRoom()`;
    /// removed symmetrically in `leaveCommunityRoom()`. Feed's `CreatePostViewModel`
    /// posts this same notification (reused, not community-specific) once its
    /// delayed AI-tag refetch confirms tags are ready. This view model isn't one
    /// of `.postUpdated`'s original observers (`FeedViewModel`/`ProfileViewModel`),
    /// so it needs its own to patch `posts` the same way `pinPost`/`unpinPost` do.
    private var postUpdatedObserver: NSObjectProtocol?
    /// A seller re-upped an item from its card here: the new post replaces the
    /// old one and goes to the top, as the server now sorts it.
    private var listingReuppedObserver: NSObjectProtocol?

    init(communityId: String, token: String, currentUserId: String) {
        self.communityId  = communityId
        self.token        = token
        self.currentUserId = currentUserId
    }

    // MARK: - Fetch

    func fetchAll() async {
        // Load the community first: a private community 403s the posts/members
        // endpoints for non-members, so firing them unconditionally produced a
        // spurious error alert plus a misleading "No posts yet". The view shows
        // a dedicated locked state for that case instead.
        await fetchDetail()
        guard community?.isMember == true || community?.privacy == .public else { return }
        async let feed: ()   = fetchPosts(reset: true)
        async let roster: () = fetchMembers()
        _ = await (feed, roster)
    }

    /// Pull-to-refresh. The system spinner shows above the cover; the page
    /// used to draw its own as well, which stacked into a double spinner.
    func refresh() async {
        await fetchAll()
    }

    func fetchDetail() async {
        do {
            let loaded = try await repository.fetchDetail(communityId: communityId, token: token)
            community = loaded
            if loaded.isMember {
                joinStatus = .joined
            } else if loaded.joinRequestStatus == "pending" {
                joinStatus = .pending
            } else {
                joinStatus = .notMember
            }
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
    }

    func fetchPosts(reset: Bool = false) async {
        // A refresh keeps the current posts on screen until the new page is in:
        // emptying them first showed a second spinner, and "No posts yet" if the
        // refresh was cut short.
        if reset { postOffset = 0; canLoadMorePosts = true }
        // One in-flight page at a time. Several CommunityPostCard `.task`
        // callbacks fire loadMorePostsIfNeeded concurrently, and without this
        // they all read the same postOffset and duplicate / skip a page.
        guard !isLoadingPosts else { return }
        guard canLoadMorePosts else { return }
        isLoadingPosts = true
        do {
            let newPosts = try await repository.fetchPosts(
                communityId: communityId, limit: pageSize, offset: postOffset, token: token
            )
            if reset { posts = newPosts } else { posts.append(contentsOf: newPosts) }
            postOffset += newPosts.count
            canLoadMorePosts = newPosts.count == pageSize
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
        isLoadingPosts = false
    }

    func loadMorePostsIfNeeded(currentPost: Post) async {
        guard let last = posts.last, last.id == currentPost.id else { return }
        await fetchPosts()
    }

    func fetchMembers() async {
        isLoadingMembers = true
        do {
            members = try await repository.fetchMembers(communityId: communityId, token: token)
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
        isLoadingMembers = false
    }

    // MARK: - WebSocket / Realtime

    /// Join this community's realtime room (`community:<id>`) and register
    /// live listeners, call from the detail view's `.onAppear`. Mirrors
    /// `ChatViewModel.joinConversation()`'s exact structure, adapted to
    /// `join_community`/`leave_community` (which additionally ack, unlike
    /// `join_conversation`).
    func joinCommunityRoom() {
        // Coming back from a screen pushed on top finds the room still open.
        guard !isInRoom else { return }
        isInRoom = true
        emitJoinCommunity()

        // Re-emit `join_community` after a socket reconnect, server-side room
        // membership is lost on disconnect, but the listeners below stay live.
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .webSocketDidReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitJoinCommunity()
        }

        // A post's tags changed (e.g. edited), patch the refreshed post's
        // `tags` into `posts` in place, same shape as
        // `pinPost`/`unpinPost` below. Feed's `Post` model is what the
        // notification carries (shared across Feed/Community since both post
        // types share the same underlying `id` space), so only `.tags` is read.
        postUpdatedObserver = NotificationCenter.default.addObserver(
            forName: .postUpdated, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let post = notification.userInfo?["post"] as? Post,
                  let idx = self.posts.firstIndex(where: { $0.id == post.id }) else { return }
            self.posts[idx].tags = post.tags
        }

        listingReuppedObserver = NotificationCenter.default.addObserver(
            forName: .listingReupped, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let oldId = notification.userInfo?["oldId"] as? String,
                  let post = notification.userInfo?["post"] as? Post,
                  let idx = self.posts.firstIndex(where: { $0.id == oldId }) else { return }
            // Not `prependPost`: a re-up isn't a new post, so the count stays.
            self.posts.remove(at: idx)
            self.posts.insert(post, at: 0)
        }

        // A new post (text/poll/event) was created in this community.
        ws.on("community_post_created", tag: "community") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  (dict["community_id"] as? String) == self.communityId,
                  let post = self.decodePost(dict) else { return }
            if !self.posts.contains(where: { $0.id == post.id }) {
                self.prependPost(post)
            }
        }

        // A post's like count changed. `isLiked` in the payload reflects the
        // ACTING user's like state. Only apply it here when that user is me;
        // every other viewer's client should only see the count move, not have
        // its own `isLiked` flipped underneath it. `CommunityPostCard` mirrors
        // `posts[i]` via `onChange`, so this write is enough to update the UI.
        ws.on("community_post_liked", tag: "community") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let postId = dict["postId"] as? String,
                  let likeCount = dict["likeCount"] as? Int,
                  let idx = self.posts.firstIndex(where: { $0.id == postId }) else { return }
            self.posts[idx].likeCount = likeCount
            if let userId = dict["userId"] as? String, userId == self.currentUserId,
               let isLiked = dict["isLiked"] as? Bool {
                self.posts[idx].isLiked = isLiked
            }
        }

        // Someone's role changed (promote, demote, admin hand-over): update
        // the badges and, when it's the viewer, their staff menu.
        ws.on("community_role_changed", tag: "community") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  (dict["community_id"] as? String) == self.communityId,
                  let changes = dict["changes"] as? [[String: Any]] else { return }
            for change in changes {
                guard let userId = change["user_id"] as? String,
                      let role = (change["role"] as? String).flatMap(MemberRole.init(rawValue:)) else { continue }
                self.setMemberRole(userId, role)
                if userId == self.currentUserId { self.community?.role = role }
            }
        }

        // The admin disbanded it while this page was open.
        ws.on("community_disbanded", tag: "community") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  (dict["community_id"] as? String) == self.communityId,
                  self.community?.role != .admin else { return }
            self.wasDisbanded = true
        }

        // A comment was added to a post. Patch the count only; the comment
        // list itself is fetched fresh by `CommentSheet` when it's opened.
        ws.on("community_post_commented", tag: "community") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  let postId = dict["postId"] as? String,
                  let commentCount = dict["commentCount"] as? Int,
                  let idx = self.posts.firstIndex(where: { $0.id == postId }) else { return }
            self.posts[idx].commentCount = commentCount
        }
    }

    /// Leave this community's realtime room and deregister listeners. Call
    /// from the detail view's `.onDisappear`.
    func leaveCommunityRoom() {
        guard isInRoom else { return }
        isInRoom = false
        if let reconnectObserver {
            NotificationCenter.default.removeObserver(reconnectObserver)
            self.reconnectObserver = nil
        }
        if let postUpdatedObserver {
            NotificationCenter.default.removeObserver(postUpdatedObserver)
            self.postUpdatedObserver = nil
        }
        if let listingReuppedObserver {
            NotificationCenter.default.removeObserver(listingReuppedObserver)
            self.listingReuppedObserver = nil
        }
        ws.emit("leave_community", communityId)
        ws.off("community_post_created", tag: "community")
        ws.off("community_post_liked", tag: "community")
        ws.off("community_post_commented", tag: "community")
        ws.off("community_role_changed", tag: "community")
        ws.off("community_disbanded", tag: "community")
    }

    /// Emits `join_community` for this community's room. Factored out of
    /// `joinCommunityRoom()` so it can also be called after a socket reconnect
    /// without re-registering the listeners above (which are still live).
    /// Unlike `join_conversation`, this acks. A rejection (e.g. somehow not a
    /// member anymore) is logged rather than silently dropped, but doesn't
    /// interrupt the read-only feed the member already sees via REST.
    private func emitJoinCommunity() {
        ws.emit("join_community", communityId) { result in
            if case .failure(let err) = result {
                #if DEBUG
                print("[CommunityDetailViewModel] join_community failed: \(err)")
                #endif
            }
        }
    }

    /// Decodes a `community_post_created` socket payload the same way the
    /// REST post list does. The payload is the full post row (same columns
    /// `buildPostSelect` projects, which now includes `community` itself
    /// whenever `community_id` is set. See PostStore.buildPostSelect), so
    /// `PostDTO` decodes it directly. `community` is filled in from the
    /// community already loaded here only as a defensive fallback, in case a
    /// server payload predates that projection.
    private func decodePost(_ payload: Any) -> Post? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        guard var post = try? JSONDecoder.makeISO8601().decode(PostDTO.self, from: json).toPost() else {
            return nil
        }
        if post.community == nil, let community {
            post.community = CommunityRef(id: community.id, name: community.name, iconEmoji: community.iconEmoji,
                                          avatarUrl: community.avatarUrl, privacy: community.privacy.rawValue,
                                          audience: post.community?.audience ?? .members)
        }
        return post
    }

    // MARK: - Feed helpers

    // Read `postCount` into a local BEFORE assigning, same as `AppState`'s
    // `.postDeleted` observer, reading and writing `community?.postCount` in
    // the same statement triggers a Swift exclusivity-access crash
    // (overlapping getter/setter access on the @Observable `community`
    // property).
    /// Set after posting into a community that approves posts first.
    var awaitingApprovalNotice = false

    func prependPost(_ post: Post) {
        // Held for approval: not in the feed yet (it's in Manage your content).
        guard post.publishStatus != "pending" else {
            awaitingApprovalNotice = true
            return
        }
        posts.insert(post, at: 0)
        if let currentCount = community?.postCount {
            community?.postCount = currentCount + 1
        }
    }

    func removePost(id: String) {
        posts.removeAll { $0.id == id }
        if let currentCount = community?.postCount, currentCount > 0 {
            community?.postCount = currentCount - 1
        }
    }

    // MARK: - Join / Request

    /// Non-members get a "Join to post" prompt where the post bar would be.
    /// Pending members see nothing: they already asked and can't act on it.
    var showsJoinToPost: Bool {
        community != nil && community?.isMember == false && joinStatus == .notMember
    }

    func requestToJoin() async {
        guard joinStatus == .notMember else { return }
        joinStatus = .loading
        do {
            let status = try await repository.requestToJoin(communityId: communityId, token: token)
            if status == "joined" {
                community?.isMember    = true
                community?.memberCount += 1
                joinStatus = .joined
            } else {
                joinStatus = .pending
            }
        } catch {
            joinStatus = .notMember
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Mute (feed-visibility only)

    func toggleMute() async {
        guard let muted = community?.isMuted else { return }
        do {
            if muted {
                try await repository.unmute(communityId: communityId, token: token)
            } else {
                try await repository.mute(communityId: communityId, token: token)
            }
            community?.isMuted = !muted
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Community settings

    func setPinned(_ pinned: Bool) async {
        guard community?.isPinned != pinned else { return }
        community?.isPinned = pinned
        do {
            try await repository.setPinned(pinned, communityId: communityId, token: token)
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
        } catch {
            community?.isPinned = !pinned
            errorMessage = friendlyError(error)
        }
    }

    func setNotifyLevel(_ level: CommunityNotifyLevel) async {
        let previous = community?.notifyLevel
        guard previous != level else { return }
        community?.notifyLevel = level
        do {
            try await repository.setNotifyLevel(level, communityId: communityId, token: token)
        } catch {
            community?.notifyLevel = previous
            errorMessage = friendlyError(error)
        }
    }

    func setHiddenFromFeed(_ hidden: Bool) async {
        guard community?.isMuted != hidden else { return }
        await toggleMute()
    }

    /// True once left. The page closes.
    func leave() async -> Bool {
        do {
            try await repository.leave(communityId: communityId, token: token)
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    /// After Edit community saved.
    func applyEdited(_ updated: Community) {
        community = community.map {
            var c = updated
            c.isMember = $0.isMember; c.isMuted = $0.isMuted; c.role = $0.role
            c.isPinned = $0.isPinned; c.notifyLevel = $0.notifyLevel
            c.joinRequestStatus = $0.joinRequestStatus
            return c
        }
        NotificationCenter.default.post(name: .communitiesChanged, object: nil)
    }

    // MARK: - Pin / Unpin

    func pinPost(_ postId: String) async {
        do {
            try await repository.pinPost(communityId: communityId, postId: postId, token: token)
            for i in posts.indices { posts[i].isPinned = (posts[i].id == postId) }
            posts.sort { $0.isPinned && !$1.isPinned }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func unpinPost(_ postId: String) async {
        do {
            try await repository.unpinPost(communityId: communityId, postId: postId, token: token)
            if let idx = posts.firstIndex(where: { $0.id == postId }) {
                posts[idx].isPinned = false
            }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Member management

    func kickMember(_ userId: String) async {
        do {
            try await repository.kickMember(communityId: communityId, userId: userId, token: token)
            members.removeAll { $0.id == userId }
            community?.memberCount = max(0, (community?.memberCount ?? 1) - 1)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func updateRole(userId: String, newRole: MemberRole) async {
        do {
            try await repository.updateMemberRole(
                communityId: communityId, userId: userId, role: newRole, token: token
            )
            setMemberRole(userId, newRole)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Makes `userId` the admin; the viewer steps down to moderator.
    func transferAdmin(to userId: String, currentUserId: String) async {
        do {
            try await repository.transferAdmin(communityId: communityId, userId: userId, token: token)
            setMemberRole(userId, .admin)
            setMemberRole(currentUserId, .moderator)
            community?.role = .moderator
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Disband / restore / ban (admin)

    /// The community was disbanded while open here (someone else is admin).
    var wasDisbanded = false

    /// True once disbanded; the page closes.
    func disband(confirmName: String) async -> Bool {
        do {
            try await repository.disband(communityId: communityId, confirmName: confirmName, token: token)
            community?.disbandedAt = Date()
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    func restore() async {
        do {
            try await repository.restore(communityId: communityId, token: token)
            community?.disbandedAt = nil
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Removes the member and keeps them out for good.
    func banMember(_ userId: String) async {
        do {
            try await repository.banMember(communityId: communityId, userId: userId, token: token)
            members.removeAll { $0.id == userId }
            community?.memberCount = max(0, (community?.memberCount ?? 1) - 1)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Manage roles handed the admin role on: the viewer is a moderator now.
    func adminTransferredElsewhere() async {
        community?.role = .moderator
        NotificationCenter.default.post(name: .communitiesChanged, object: nil)
        await fetchMembers()
    }

    private func setMemberRole(_ userId: String, _ role: MemberRole) {
        guard let idx = members.firstIndex(where: { $0.id == userId }) else { return }
        let m = members[idx]
        members[idx] = CommunityMember(
            id: m.id, username: m.username, displayName: m.displayName,
            avatarColor: m.avatarColor, jobTitle: m.jobTitle, company: m.company,
            role: role, joinedAt: m.joinedAt,
            avatarUrl: m.avatarUrl, isFriend: m.isFriend
        )
    }
}

// MARK: - Supporting types

enum JoinStatus {
    case notMember, loading, pending, joined
}
