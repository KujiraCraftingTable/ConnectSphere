import Foundation
import Observation

@Observable
class CommunityDetailViewModel {
    var community: Community?
    var posts: [CommunityPost] = []
    var members: [CommunityMember] = []
    var isLoadingPosts = false
    var isLoadingMembers = false
    var errorMessage: String?
    var canLoadMorePosts = true
    var joinStatus: JoinStatus = .notMember

    private let communityId: String
    private let token: String
    private let currentUserId: String
    private let repository = CommunityRepository()
    private let ws = WebSocketClient.shared
    private let pageSize = 20
    private var postOffset = 0
    /// Token for the `.webSocketDidReconnect` observer registered in `joinCommunityRoom()`;
    /// removed symmetrically in `leaveCommunityRoom()` — mirrors `ChatViewModel`'s
    /// reconnect-handling exactly (see that file for why: server-side room
    /// membership doesn't survive a disconnect, but registered listeners do).
    private var reconnectObserver: NSObjectProtocol?
    /// Token for the `.postUpdated` observer registered in `joinCommunityRoom()`;
    /// removed symmetrically in `leaveCommunityRoom()`. Feed's `CreatePostViewModel`
    /// posts this same notification (reused, not community-specific) once its
    /// delayed AI-tag refetch confirms tags are ready — this view model isn't one
    /// of `.postUpdated`'s original observers (`FeedViewModel`/`ProfileViewModel`),
    /// so it needs its own to patch `posts` the same way `pinPost`/`unpinPost` do.
    private var postUpdatedObserver: NSObjectProtocol?

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
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func fetchPosts(reset: Bool = false) async {
        if reset { postOffset = 0; canLoadMorePosts = true; posts = [] }
        // One in-flight page at a time — several CommunityPostCard `.task`
        // callbacks fire loadMorePostsIfNeeded concurrently, and without this
        // they all read the same postOffset and duplicate / skip a page.
        guard !isLoadingPosts else { return }
        guard canLoadMorePosts else { return }
        isLoadingPosts = true
        do {
            let newPosts = try await repository.fetchPosts(
                communityId: communityId, limit: pageSize, offset: postOffset, token: token
            )
            posts.append(contentsOf: newPosts)
            postOffset += newPosts.count
            canLoadMorePosts = newPosts.count == pageSize
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoadingPosts = false
    }

    func loadMorePostsIfNeeded(currentPost: CommunityPost) async {
        guard let last = posts.last, last.id == currentPost.id else { return }
        await fetchPosts()
    }

    func fetchMembers() async {
        isLoadingMembers = true
        do {
            members = try await repository.fetchMembers(communityId: communityId, token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoadingMembers = false
    }

    // MARK: - WebSocket / Realtime

    /// Join this community's realtime room (`community:<id>`) and register
    /// live listeners — call from the detail view's `.onAppear`. Mirrors
    /// `ChatViewModel.joinConversation()`'s exact structure, adapted to
    /// `join_community`/`leave_community` (which additionally ack, unlike
    /// `join_conversation`).
    func joinCommunityRoom() {
        emitJoinCommunity()

        // Re-emit `join_community` after a socket reconnect — server-side room
        // membership is lost on disconnect, but the listeners below stay live.
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .webSocketDidReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.emitJoinCommunity()
        }

        // AI tags becoming visible after opting in on create — patch the
        // refreshed post's `tags` into `posts` in place, same shape as
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
        // ACTING user's like state — only apply it here when that user is me;
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

        // A comment was added to a post — patch the count only; the comment
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

    /// Leave this community's realtime room and deregister listeners — call
    /// from the detail view's `.onDisappear`.
    func leaveCommunityRoom() {
        if let reconnectObserver {
            NotificationCenter.default.removeObserver(reconnectObserver)
            self.reconnectObserver = nil
        }
        if let postUpdatedObserver {
            NotificationCenter.default.removeObserver(postUpdatedObserver)
            self.postUpdatedObserver = nil
        }
        ws.emit("leave_community", communityId)
        ws.off("community_post_created", tag: "community")
        ws.off("community_post_liked", tag: "community")
        ws.off("community_post_commented", tag: "community")
    }

    /// Emits `join_community` for this community's room — factored out of
    /// `joinCommunityRoom()` so it can also be called after a socket reconnect
    /// without re-registering the listeners above (which are still live).
    /// Unlike `join_conversation`, this acks — a rejection (e.g. somehow not a
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
    /// REST post list does — the payload is the full post row (same columns
    /// `buildPostSelect` projects) plus `community_id`, so `CommunityPostDTO`
    /// decodes it directly. Unlike `GET /communities/:id/posts`, the socket
    /// emit doesn't add the joined `community` object (it broadcasts the raw
    /// row from `createCommunityPost`/`findById`, not `getPostsByCommunity`'s
    /// query) — fill it in from the community already loaded here so a
    /// live-arriving post's community badge matches a REST-fetched one's.
    private func decodePost(_ payload: Any) -> CommunityPost? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        guard var post = try? JSONDecoder.makeISO8601().decode(CommunityPostDTO.self, from: json).toCommunityPost() else {
            return nil
        }
        if post.community == nil, let community {
            post.community = CommunityRef(id: community.id, name: community.name, iconEmoji: community.iconEmoji, avatarUrl: community.avatarUrl)
        }
        return post
    }

    // MARK: - Feed helpers

    // Read `postCount` into a local BEFORE assigning, same as `AppState`'s
    // `.postDeleted` observer — reading and writing `community?.postCount` in
    // the same statement triggers a Swift exclusivity-access crash
    // (overlapping getter/setter access on the @Observable `community`
    // property).
    func prependPost(_ post: CommunityPost) {
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

    // MARK: - Delete post (moved from View)

    func deletePost(_ post: CommunityPost) async {
        do {
            try await repository.deletePost(postId: post.id, token: token)
            removePost(id: post.id)
        } catch {
            errorMessage = Bundle.app.loc("Could not delete post.")
        }
    }

    // MARK: - Join / Request

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
            if let idx = members.firstIndex(where: { $0.id == userId }) {
                let m = members[idx]
                members[idx] = CommunityMember(
                    id: m.id, username: m.username, displayName: m.displayName,
                    avatarColor: m.avatarColor, jobTitle: m.jobTitle, company: m.company,
                    role: newRole, joinedAt: m.joinedAt
                )
            }
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}

// MARK: - Supporting types

enum JoinStatus {
    case notMember, loading, pending, joined
}
