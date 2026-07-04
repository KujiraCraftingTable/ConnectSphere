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
    private let repository = CommunityRepository()
    private let pageSize = 20
    private var postOffset = 0

    init(communityId: String, token: String) {
        self.communityId = communityId
        self.token       = token
    }

    // MARK: - Fetch

    func fetchAll() async {
        async let detail: () = fetchDetail()
        async let feed: ()   = fetchPosts(reset: true)
        async let roster: () = fetchMembers()
        _ = await (detail, feed, roster)
    }

    func fetchDetail() async {
        do {
            community = try await repository.fetchDetail(communityId: communityId, token: token)
            if community?.isMember == true { joinStatus = .joined }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func fetchPosts(reset: Bool = false) async {
        if reset { postOffset = 0; canLoadMorePosts = true; posts = [] }
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

    // MARK: - Feed helpers

    func prependPost(_ post: CommunityPost) {
        posts.insert(post, at: 0)
        community?.postCount += 1
    }

    func removePost(id: String) {
        posts.removeAll { $0.id == id }
        if community?.postCount ?? 0 > 0 { community?.postCount -= 1 }
    }

    // MARK: - Delete post (moved from View)

    func deletePost(_ post: CommunityPost) async {
        do {
            try await repository.deletePost(postId: post.id, token: token)
            removePost(id: post.id)
        } catch {
            errorMessage = "Could not delete post."
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
            for i in posts.indices { posts[i] = CommunityPost(
                id: posts[i].id, content: posts[i].content, postType: posts[i].postType,
                isPinned: posts[i].id == postId, author: posts[i].author,
                community: posts[i].community, likeCount: posts[i].likeCount,
                commentCount: posts[i].commentCount, isLiked: posts[i].isLiked,
                createdAt: posts[i].createdAt, pollData: posts[i].pollData,
                eventData: posts[i].eventData
            )}
            posts.sort { $0.isPinned && !$1.isPinned }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func unpinPost(_ postId: String) async {
        do {
            try await repository.unpinPost(communityId: communityId, postId: postId, token: token)
            if let idx = posts.firstIndex(where: { $0.id == postId }) {
                posts[idx] = CommunityPost(
                    id: posts[idx].id, content: posts[idx].content, postType: posts[idx].postType,
                    isPinned: false, author: posts[idx].author,
                    community: posts[idx].community, likeCount: posts[idx].likeCount,
                    commentCount: posts[idx].commentCount, isLiked: posts[idx].isLiked,
                    createdAt: posts[idx].createdAt, pollData: posts[idx].pollData,
                    eventData: posts[idx].eventData
                )
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
