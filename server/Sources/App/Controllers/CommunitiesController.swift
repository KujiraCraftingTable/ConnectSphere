import Vapor
import SQLKit

/// Port of `backend/src/routes/communityRoutes.js` + `communityController.js` +
/// `communityService.js`. Notifications/socket side effects deferred to the
/// notification port (same phase) / Phase 4. `clientError` in the Node service
/// → `Abort` ({status,code,message}); the controllers' own inline guards →
/// `Abort` too (they use `err.status = …; next(err)`).
///
/// Review fixes folded: reviewJoinRequest status-guard → 409; joinCommunity
/// ON CONFLICT + counter-on-real-insert; incrementMemberCount 0 floor;
/// create/approve+join+counter wrapped in one txn.
struct CommunitiesController {
    static let validTypes = ["fandom", "work"]
    static let validPrivacy = ["public", "private"]
    static let validRoles = ["admin", "moderator", "member"]

    static func register(routes: any RoutesBuilder) {
        let c = routes.grouped("communities").grouped(AuthMiddleware())
        c.get("me", use: myCommunities)
        c.get("recommendations", use: recommendations)
        c.get("trending", use: trending)
        c.get("discover", use: discover)
        c.post(use: create)
        c.get(use: search)
        c.get(":id", use: getOne)
        c.post(":id", "join", use: join)
        c.delete(":id", "leave", use: leave)
        c.get(":id", "members", use: members)
        c.get(":id", "posts", use: posts)
        c.post(":id", "posts", use: createPost)
        c.post(":id", "request-join", use: requestJoin)
        c.get(":id", "join-requests", use: listJoinRequests)
        c.patch(":id", "join-requests", ":requestId", use: reviewJoinRequest)
        c.post(":id", "posts", ":postId", "pin", use: pinPost)
        c.delete(":id", "posts", ":postId", "pin", use: unpinPost)
        c.delete(":id", "members", ":userId", use: kickMember)
        c.patch(":id", "members", ":userId", "role", use: updateRole)
        c.post(":id", "tags", use: setTags)
        c.patch(":id", use: update)
        c.put(":id", "mute", use: mute)
        c.delete(":id", "mute", use: unmute)
        // moderation / analytics / member-report → ReportsController (same phase)
        ReportsController.registerCommunityRoutes(on: c)
    }

    static func staff(_ role: String?) -> Bool { role == "admin" || role == "moderator" }

    // MARK: create

    struct CreateBody: Content {
        var name: String?; var description: String?; var type: String?; var privacy: String?
        var icon_emoji: String?; var cover_color: String?; var avatar_url: String?
    }
    static func create(_ req: Request) async throws -> Response {
        let b = try req.content.decode(CreateBody.self)
        let name = (b.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Community name is required") }
        guard name.count >= 3 else { throw Abort(.badRequest, reason: "Community name must be at least 3 characters") }
        guard name.count <= 100 else { throw Abort(.badRequest, reason: "Community name must be at most 100 characters") }
        guard let type = b.type, validTypes.contains(type) else { throw Abort(.badRequest, reason: "type must be fandom or work") }
        if let p = b.privacy, !validPrivacy.contains(p) { throw Abort(.badRequest, reason: "privacy must be public or private") }
        if let d = b.description, d.count > 500 { throw Abort(.badRequest, reason: "Description must be at most 500 characters") }

        let privacy = b.privacy ?? "public"
        let icon = b.icon_emoji ?? "👥"
        let cover = b.cover_color ?? "#7F5AF0"
        let desc = b.description?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let avatarURL = MediaPath.storable(b.avatar_url)

        var newID = ""
        do {
            try await req.db.tx { t in
                struct R: Decodable { let id: String }
                newID = try await t.raw("""
                    INSERT INTO communities (name, description, type, privacy, icon_emoji, avatar_url, cover_color, created_by)
                    VALUES (\(bind: name), \(bind: desc), \(bind: type), \(bind: privacy), \(bind: icon), \(bind: avatarURL), \(bind: cover), \(uuid: req.userID))
                    RETURNING id::text AS id
                    """).first(decoding: R.self)!.id
                _ = try await CommunityStore.joinCommunity(newID, req.userID, role: "admin", on: t)
                try await CommunityStore.incrementMemberCount(newID, 1, on: t)
            }
        } catch {
            if PGError.isUniqueViolation(error) { throw Abort(.conflict, reason: "A community with this name already exists") }
            throw error
        }
        guard let community = try await CommunityStore.byID(newID, viewer: req.userID, on: req.db.sql()) else { throw Abort(.internalServerError) }
        return try await ConnectionsController.encode(DataResponse(data: community), req, .created)
    }

    // MARK: update (avatar/name/description/icon/cover — admin/moderator only)

    struct UpdateBody: Content {
        var name: String?; var description: String?; var privacy: String?
        var icon_emoji: String?; var cover_color: String?; var avatar_url: String?
    }
    static func update(_ req: Request) async throws -> DataResponse<CommunityStore.CommunityDetail> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can edit this community")
        }
        let b = try req.content.decode(UpdateBody.self)
        if let name = b.name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3, trimmed.count <= 100 else {
                throw Abort(.badRequest, reason: "Community name must be 3-100 characters")
            }
        }
        if let d = b.description, d.count > 500 { throw Abort(.badRequest, reason: "Description must be at most 500 characters") }
        if let p = b.privacy, !CommunitiesController.validPrivacy.contains(p) { throw Abort(.badRequest, reason: "privacy must be public or private") }
        guard try await CommunityStore.update(id, name: b.name, description: b.description, privacy: b.privacy,
            iconEmoji: b.icon_emoji, coverColor: b.cover_color, avatarURL: b.avatar_url.map { MediaPath.storable($0) ?? "" }, on: db) else {
            throw Abort(.notFound, reason: "Community not found")
        }
        guard let community = try await CommunityStore.byID(id, viewer: req.userID, on: db) else { throw Abort(.internalServerError) }
        return DataResponse(data: community)
    }

    // MARK: search / me / getOne

    static func search(_ req: Request) async throws -> DataListResponse<CommunityStore.CommunityRow> {
        let sq = (try? req.query.get(String.self, at: "query")) ?? ""
        let type = (try? req.query.get(String.self, at: "type")).flatMap { validTypes.contains($0) ? $0 : nil }
        let tags = ((try? req.query.get(String.self, at: "tags")) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let sortQ = (try? req.query.get(String.self, at: "sort")) ?? "members"
        let sort = ["members", "newest", "trending"].contains(sortQ) ? sortQ : "members"
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 20, 50)
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        return DataListResponse(data: try await CommunityStore.search(
            searchQuery: sq, type: type, tags: tags, sort: sort, limit: limit, offset: offset,
            viewer: req.userID, on: req.db.sql()))
    }

    static func myCommunities(_ req: Request) async throws -> DataListResponse<CommunityStore.CommunityRow> {
        DataListResponse(data: try await CommunityStore.byUser(req.userID, on: req.db.sql()))
    }

    static func loadForView(_ id: String, _ req: Request) async throws -> CommunityStore.CommunityDetail {
        guard var community = try await CommunityStore.byID(id, viewer: req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Community not found")
        }
        if community.privacy == "private" && !(community.is_member ?? false) { community.description = nil }
        return community
    }
    static func getOne(_ req: Request) async throws -> DataResponse<CommunityStore.CommunityDetail> {
        DataResponse(data: try await loadForView(req.parameters.get("id")!, req))
    }

    // MARK: membership

    struct OKMsg: Content { var status = "ok"; var message: String }

    static func join(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard let community = try await CommunityStore.byID(id, viewer: nil, on: db) else { throw Abort(.notFound, reason: "Community not found") }
        if community.privacy == "private" { throw Abort(.forbidden, reason: "This community requires a request to join") }
        if try await CommunityStore.isBanned(id, req.userID, on: db) { throw Abort(.forbidden, reason: "You are banned from this community") }
        if try await CommunityStore.membership(id, req.userID, on: db) != nil { throw Abort(.conflict, reason: "You are already a member of this community") }
        try await req.db.tx { t in
            if try await CommunityStore.joinCommunity(id, req.userID, on: t) {
                try await CommunityStore.incrementMemberCount(id, 1, on: t)
            }
        }
        return OKMsg(message: "Joined community")
    }

    static func leave(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard let role = try await CommunityStore.membership(id, req.userID, on: db) else {
            throw Abort(.badRequest, reason: "You are not a member of this community")
        }
        if role == "admin", try await CommunityStore.countAdmins(id, on: db) <= 1 {
            throw Abort(.badRequest, reason: "You are the sole admin — transfer the role before leaving")
        }
        try await req.db.tx { t in
            _ = try await CommunityStore.leaveCommunity(id, req.userID, on: t)
            try await CommunityStore.incrementMemberCount(id, -1, on: t)
            try await CommunityStore.deleteRequest(id, req.userID, on: t)
        }
        return OKMsg(message: "Left community")
    }

    // MARK: mute / unmute (feed-visibility only — does not unfollow/leave)

    static func mute(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard try await CommunityStore.membership(id, req.userID, on: db) != nil else {
            throw Abort(.badRequest, reason: "You are not a member of this community")
        }
        try await CommunityStore.setMuted(id, req.userID, true, on: db)
        return OKMsg(message: "Community muted")
    }

    static func unmute(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard try await CommunityStore.membership(id, req.userID, on: db) != nil else {
            throw Abort(.badRequest, reason: "You are not a member of this community")
        }
        try await CommunityStore.setMuted(id, req.userID, false, on: db)
        return OKMsg(message: "Community unmuted")
    }

    static func members(_ req: Request) async throws -> DataListResponse<CommunityStore.MemberRow> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard let community = try await CommunityStore.byID(id, viewer: nil, on: db) else { throw Abort(.notFound, reason: "Community not found") }
        if community.privacy == "private", try await CommunityStore.membership(id, req.userID, on: db) == nil {
            throw Abort(.forbidden, reason: "You must be a member to view the member list")
        }
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        return DataListResponse(data: try await CommunityStore.members(id, limit: limit, offset: offset, on: db))
    }

    // MARK: posts

    static func posts(_ req: Request) async throws -> DataListResponse<PostObject> {
        let id = req.parameters.get("id")!
        let community = try await loadForView(id, req)
        if community.privacy == "private" && !(community.is_member ?? false) {
            throw Abort(.forbidden, reason: "You must be a member to view this community")
        }
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let tag = (try? req.query.get(String.self, at: "tag")).flatMap { $0.isEmpty ? nil : $0 }
        let search = (try? req.query.get(String.self, at: "search")).flatMap { $0.isEmpty ? nil : $0 }
        return DataListResponse(data: try await PostStore.getPostsByCommunity(id, viewer: req.userID, tag: tag, search: search, limit: limit, offset: offset, on: req.db.sql()))
    }

    static func createPost(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let b = try req.content.decode(PostsController.CreateBody.self)
        let hashtags = b.hashtags ?? []
        let postType = b.post_type ?? "text"
        let publishing = try Publishing.from(b.publish, at: b.publish_at)
        try await PostsController.checkReplacedDraft(b.replaces_draft, req)
        var post: PostObject
        if postType == "poll" {
            post = try await PostService.createPollPost(authorID: req.userID, communityID: id, content: b.content,
                options: b.options, endsAt: b.endsAt, hashtags: hashtags, mode: nil, privacy: nil, publishing: publishing, on: req.db)
        } else if postType == "event" {
            post = try await PostService.createEventPost(authorID: req.userID, communityID: id, content: b.content,
                eventTitle: b.eventData?.title, eventLocation: b.eventData?.location,
                eventStartsAt: b.eventData?.startsAt, eventEndsAt: b.eventData?.endsAt,
                hashtags: hashtags, mode: nil, privacy: nil, publishing: publishing, on: req.db)
        } else if postType == "job" {
            post = try await PostService.createJobPost(authorID: req.userID, communityID: id, content: b.content,
                jobTitle: b.jobData?.title, jobCompany: b.jobData?.company, jobLocation: b.jobData?.location,
                employmentType: b.jobData?.employmentType, salaryRange: b.jobData?.salaryRange,
                applicationDeadline: b.jobData?.applicationDeadline,
                hashtags: hashtags, mode: nil, privacy: nil, publishing: publishing, on: req.db)
        } else {
            post = try await PostService.createTextCommunityPost(userID: req.userID, content: b.content, communityID: id,
                imageUrls: PostsController.normalizeImageUrls(b.image_urls), linkUrl: b.link_url?.nilIfEmpty,
                articleTitle: b.article_title?.nilIfEmpty, hashtags: hashtags, mode: nil, privacy: nil, publishing: publishing, on: req.db)
        }
        if b.image_alts != nil {
            post.image_alts = try await PostStore.setImageAlts(post.id, b.image_alts, on: req.db.sql())
        }
        if let old = b.replaces_draft {
            try await PostStore.deleteUnpublished(old, author: req.userID, on: req.db.sql())
        }
        if publishing.isLive { await TranslationService.enqueue(req, .post, id: post.id) }
        return try await ConnectionsController.encode(DataResponse(data: post), req, .created)
    }

    // MARK: join requests

    struct RequestJoinResult: Content { var status: String; @NullCoded var requestId: String? }
    static func requestJoin(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard let community = try await CommunityStore.byID(id, viewer: nil, on: db) else { throw Abort(.notFound, reason: "Community not found") }
        if try await CommunityStore.membership(id, req.userID, on: db) != nil { throw Abort(.conflict, reason: "You are already a member of this community") }
        if try await CommunityStore.isBanned(id, req.userID, on: db) { throw Abort(.forbidden, reason: "You are banned from this community") }
        if community.privacy == "public" {
            try await req.db.tx { t in
                if try await CommunityStore.joinCommunity(id, req.userID, on: t) {
                    try await CommunityStore.incrementMemberCount(id, 1, on: t)
                }
            }
            return try await ConnectionsController.encode(DataResponse(data: RequestJoinResult(status: "joined", requestId: nil)), req, .ok)
        }
        if try await CommunityStore.hasExistingRequest(id, req.userID, on: db) == "pending" {
            throw Abort(.conflict, reason: "You already have a pending request")
        }
        let requestID = try await CommunityStore.createRequest(id, req.userID, on: db)
        // TODO(notify): fanOutCommunityNotification + join_request_created emit
        return try await ConnectionsController.encode(DataResponse(data: RequestJoinResult(status: "pending", requestId: requestID)), req, .accepted)
    }

    static func listJoinRequests(_ req: Request) async throws -> DataListResponse<CommunityStore.JoinRequestRow> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can view join requests")
        }
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        return DataListResponse(data: try await CommunityStore.pendingRequests(id, limit: limit, offset: offset, on: db))
    }

    struct ReviewBody: Content { var status: String? }
    static func reviewJoinRequest(_ req: Request) async throws -> DataResponse<CommunityStore.ReviewedRow> {
        let requestID = req.parameters.get("requestId")!
        let db = req.db.sql()
        guard let status = try req.content.decode(ReviewBody.self).status, ["approved", "rejected"].contains(status) else {
            throw Abort(.badRequest, reason: "status must be approved or rejected")
        }
        guard let request = try await CommunityStore.requestByID(requestID, on: db) else { throw Abort(.notFound, reason: "Request not found") }
        if request.status != "pending" { throw Abort(.conflict, reason: "This request has already been reviewed") }
        guard staff(try await CommunityStore.membership(request.community_id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can review requests")
        }
        var updated: CommunityStore.ReviewedRow?
        try await req.db.tx { t in
            updated = try await CommunityStore.reviewRequest(requestID, reviewerID: req.userID, status: status, on: t)
            guard updated != nil, status == "approved" else { return }
            if try await CommunityStore.joinCommunity(request.community_id, request.user_id, on: t) {
                try await CommunityStore.incrementMemberCount(request.community_id, 1, on: t)
            }
        }
        guard let u = updated else { throw Abort(.conflict, reason: "This request has already been reviewed") }
        // TODO(notify): join_approved/join_rejected + join_request_reviewed / community_joined emits
        return DataResponse(data: u)
    }

    // MARK: pin / unpin / kick / role

    static func pinPost(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!, postID = req.parameters.get("postId")!
        let db = req.db.sql()
        guard staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can pin posts")
        }
        guard try await CommunityStore.pinPost(postID, id, adminID: req.userID, on: db) else {
            throw Abort(.notFound, reason: "Post not found in this community")
        }
        // TODO(notify): pinned_post fan-out
        return OKMsg(message: "Post pinned")
    }
    static func unpinPost(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!, postID = req.parameters.get("postId")!
        let db = req.db.sql()
        guard staff(try await CommunityStore.membership(id, req.userID, on: db)) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can unpin posts")
        }
        guard try await CommunityStore.unpinPost(postID, id, on: db) else {
            throw Abort(.notFound, reason: "Post not found or not pinned")
        }
        return OKMsg(message: "Post unpinned")
    }

    static func kickMember(_ req: Request) async throws -> OKMsg {
        let id = req.parameters.get("id")!, targetID = req.parameters.get("userId")!
        let db = req.db.sql()
        if targetID == req.userID { throw Abort(.badRequest, reason: "You cannot remove yourself") }
        guard let requesterRole = try await CommunityStore.membership(id, req.userID, on: db), staff(requesterRole) else {
            throw Abort(.forbidden, reason: "Only admins and moderators can remove members")
        }
        guard let targetRole = try await CommunityStore.membership(id, targetID, on: db) else {
            throw Abort(.notFound, reason: "User is not a member of this community")
        }
        if requesterRole == "moderator" && targetRole != "member" { throw Abort(.forbidden, reason: "Moderators can only remove regular members") }
        if targetRole == "admin" && requesterRole != "admin" { throw Abort(.forbidden, reason: "Only admins can remove other admins") }
        try await req.db.tx { t in
            _ = try await CommunityStore.kickMember(id, targetID, on: t)
            try await CommunityStore.incrementMemberCount(id, -1, on: t)
            try await CommunityStore.deleteRequest(id, targetID, on: t)
        }
        return OKMsg(message: "Member removed")
    }

    struct RoleBody: Content { var role: String? }
    static func updateRole(_ req: Request) async throws -> DataResponse<CommunityStore.RoleRow> {
        let id = req.parameters.get("id")!, targetID = req.parameters.get("userId")!
        let db = req.db.sql()
        guard let newRole = try req.content.decode(RoleBody.self).role, validRoles.contains(newRole) else {
            throw Abort(.badRequest, reason: "Invalid role")
        }
        guard try await CommunityStore.membership(id, req.userID, on: db) == "admin" else {
            throw Abort(.forbidden, reason: "Only admins can change member roles")
        }
        guard let targetRole = try await CommunityStore.membership(id, targetID, on: db) else {
            throw Abort(.notFound, reason: "User is not a member of this community")
        }
        if targetRole == "admin" && newRole != "admin", try await CommunityStore.countAdmins(id, on: db) <= 1 {
            throw Abort(.badRequest, reason: "Cannot demote the only admin — promote another admin first")
        }
        guard let result = try await CommunityStore.updateRole(id, targetID, newRole, on: db) else { throw Abort(.internalServerError) }
        // TODO(notify): role_changed
        return DataResponse(data: result)
    }

    // MARK: recommendations / trending / discover — port of recommendationService.js

    /// getRecommendations: interest-overlap list if the user has interests,
    /// else the trending list. Returns raw JSON since the two paths have
    /// different shapes (recommended carries tag_overlap / rec_score).
    static func recommendedJSON(_ userID: String, limit: Int, type: String? = nil, on db: any SQLDatabase) async throws -> Data {
        if try await CommunityStore.userHasInterests(userID, on: db) {
            return try JSONCoding.makeEncoder().encode(try await CommunityStore.recommendedCommunities(userID, limit: limit, type: type, on: db))
        }
        return try JSONCoding.makeEncoder().encode(try await CommunityStore.trendingCommunities(type: type, limit: limit, on: db))
    }

    static func recommendations(_ req: Request) async throws -> Response {
        let type = (try? req.query.get(String.self, at: "type")).flatMap { validTypes.contains($0) ? $0 : nil }
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 10, 50)
        let inner = try await recommendedJSON(req.userID, limit: limit, type: type, on: req.db.sql())
        return jsonWrapped("data", inner)
    }
    static func trending(_ req: Request) async throws -> DataListResponse<CommunityStore.CommunityRow> {
        let type = (try? req.query.get(String.self, at: "type")).flatMap { validTypes.contains($0) ? $0 : nil }
        let limit = min((try? req.query.get(Int.self, at: "limit")) ?? 20, 50)
        return DataListResponse(data: try await CommunityStore.trendingCommunities(type: type, limit: limit, on: req.db.sql()))
    }
    static func discover(_ req: Request) async throws -> Response {
        let type = (try? req.query.get(String.self, at: "type")).flatMap { validTypes.contains($0) ? $0 : nil }
        let db = req.db.sql()
        let trendingJSON = try JSONCoding.makeEncoder().encode(try await CommunityStore.trendingCommunities(type: type, limit: 10, on: db))
        let recJSON = try await recommendedJSON(req.userID, limit: 10, type: type, on: db)
        var body = Data(#"{"data":{"trending":"#.utf8)
        body.append(trendingJSON); body.append(Data(#","recommended":"#.utf8))
        body.append(recJSON); body.append(Data("}}".utf8))
        return Response(status: .ok, headers: ["content-type": "application/json; charset=utf-8"], body: .init(data: body))
    }
    static func jsonWrapped(_ key: String, _ inner: Data) -> Response {
        var body = Data("{\"\(key)\":".utf8); body.append(inner); body.append(Data("}".utf8))
        return Response(status: .ok, headers: ["content-type": "application/json; charset=utf-8"], body: .init(data: body))
    }
    struct TagsBody: Content { var tags: [String]? }
    struct TagsResult: Content { var tags: [String] }
    static func setTags(_ req: Request) async throws -> DataResponse<TagsResult> {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        guard try await CommunityStore.membership(id, req.userID, on: db) == "admin" else {
            throw Abort(.forbidden, reason: "Only admins can set tags")
        }
        let re = try! NSRegularExpression(pattern: "^[a-z0-9_-]+$")
        let tags = Array(((try req.content.decode(TagsBody.self).tags) ?? []).prefix(10))
            .filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        try await db.raw("DELETE FROM community_tags WHERE community_id = \(uuid: id)").run()
        for tag in tags {
            try await db.raw("INSERT INTO community_tags (community_id, tag) VALUES (\(uuid: id), \(bind: tag)) ON CONFLICT DO NOTHING").run()
        }
        return DataResponse(data: TagsResult(tags: tags))
    }
}
