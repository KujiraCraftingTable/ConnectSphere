import Vapor
import SQLKit

/// Post creation and publishing rules. Client errors use `Abort` (the central
/// handler renders `{status,code,message}`), not `InlineError`.
/// The community-only side effects (tag-extraction enqueue, member fan-out
/// notification, realtime broadcast, interest rebuild) are deferred:
///  - tag/embed queue  → Phase 5
///  - notifications     → Phase 3
///  - socket emits      → Phase 4
enum PostService {

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func validateMode(_ mode: String?) throws {
        if let mode, !["hobby", "work"].contains(mode) {
            throw Abort(.badRequest, reason: "mode must be hobby or work")
        }
    }

    // MARK: text post (community or Feed via createCommunityPost)

    static func createTextCommunityPost(
        userID: String, content: String?, communityID: String?,
        imageUrls: [String]?, linkUrl: String?, articleTitle: String?,
        hashtags: [String], mode: String?, privacy: String?,
        publishing: Publishing = .now,
        on db: AppDatabase
    ) async throws -> PostObject {
        let hasContent = !(content?.trimmedText.isEmpty ?? true)
        if !hasContent && linkUrl == nil && imageUrls == nil {
            throw Abort(.badRequest, reason: "Post content, link_url or image_urls is required")
        }
        if hasContent, (content!.trimmedText.count) > 2000 {
            throw Abort(.badRequest, reason: "Post content must be at most 2000 characters")
        }
        try validateMode(mode)
        if let communityID {
            guard try await CommunityMemberStore.membership(communityID, userID, on: db.sql()) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to post")
            }
        }
        let trimmed = content?.trimmedText.nilIfEmpty
        let id = try await createCommunityPostRow(
            content: trimmed, authorID: userID, communityID: communityID, postType: "text",
            imageUrls: imageUrls, linkUrl: linkUrl, articleTitle: articleTitle,
            hashtags: hashtags, mode: mode, privacy: privacy, publishing: publishing, on: db)
        if let communityID, publishing.isLive { try await CommunityMemberStore.incrementPostCount(communityID, 1, on: db.sql()) }
        // TODO(phase 5): enqueueTagExtraction; (phase 4) emit
        guard let post = try await PostStore.findById(id, viewer: userID, includeOwnUnpublished: !publishing.isLive, on: db.sql()) else {
            throw Abort(.internalServerError)
        }
        return post
    }

    /// Inserts a community post row. Mode derives from the
    /// community's type unless explicitly overridden; hashtags inserted synchronously.
    static func createCommunityPostRow(
        content: String?, authorID: String, communityID: String?, postType: String,
        imageUrls: [String]?, linkUrl: String?, articleTitle: String?,
        hashtags: [String], mode: String?, privacy: String?,
        publishing: Publishing = .now,
        on db: AppDatabase
    ) async throws -> String {
        var newID = ""
        try await db.tx { t in
            struct R: Decodable { let id: String }
            let row = try await t.raw("""
                INSERT INTO posts (author_id, content, mode, privacy, community_id, post_type, image_urls, link_url, article_title,
                                   status, publish_at)
                VALUES (
                  \(uuid: authorID), \(bind: content ?? ""),
                  COALESCE(\(bind: mode), (SELECT CASE WHEN type = 'work' THEN 'work' ELSE 'hobby' END FROM communities WHERE id = \(uuid: communityID)), 'hobby'),
                  COALESCE(\(bind: privacy), 'public'), \(uuid: communityID), \(bind: postType),
                  \(bind: imageUrls), \(bind: linkUrl), \(bind: articleTitle),
                  \(bind: publishing.status)::post_status, \(bind: publishing.publishAt)
                )
                RETURNING id
                """).first(decoding: R.self)
            newID = row!.id
            let clean = PostStore.sanitizeHashtags(hashtags)
            if !clean.isEmpty {
                try await t.raw("""
                    INSERT INTO post_tags (post_id, tag, source)
                    SELECT \(uuid: newID), UNNEST(\(bind: clean)::text[]), 'user'
                    ON CONFLICT (post_id, tag) DO NOTHING
                    """).run()
            }
        }
        return newID
    }

    // MARK: poll / event

    static func createPollPost(
        authorID: String, communityID: String?, content: String?, options: [String]?,
        endsAt: String?, hashtags: [String], mode: String?, privacy: String?,
        publishing: Publishing = .now,
        on db: AppDatabase
    ) async throws -> PostObject {
        let trimmedContent = content?.trimmedText ?? ""
        if trimmedContent.isEmpty { throw Abort(.badRequest, reason: "Post content is required") }
        if trimmedContent.count > 2000 { throw Abort(.badRequest, reason: "Post content must be at most 2000 characters") }
        guard let options, options.count >= 2 else { throw Abort(.badRequest, reason: "Poll must have at least 2 options") }
        if options.count > 6 { throw Abort(.badRequest, reason: "Poll can have at most 6 options") }
        try validateMode(mode)
        let trimmedOptions = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmedOptions.count < 2 { throw Abort(.badRequest, reason: "Poll options must not be empty") }
        if let communityID {
            guard try await CommunityMemberStore.membership(communityID, authorID, on: db.sql()) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to post")
            }
        }
        if let after = publishing.datesAfter, let endsAt,
           let d = JSONCoding.isoFractional.date(from: endsAt) ?? ISO8601DateFormatter().date(from: endsAt), d <= after {
            throw Abort(.badRequest, reason: publishing.publishAt == nil
                ? "Poll end date must be in the future" : "Poll must end after the post goes out")
        }
        let id = try await createCommunityPostRow(
            content: trimmedContent, authorID: authorID, communityID: communityID, postType: "poll",
            imageUrls: nil, linkUrl: nil, articleTitle: nil,
            hashtags: hashtags, mode: mode, privacy: privacy, publishing: publishing, on: db)
        try await PollStore.createWithOptions(postID: id, options: trimmedOptions, endsAt: endsAt, on: db.sql())
        if let communityID, publishing.isLive { try await CommunityMemberStore.incrementPostCount(communityID, 1, on: db.sql()) }
        guard let post = try await PostStore.findById(id, viewer: authorID, includeOwnUnpublished: !publishing.isLive, on: db.sql()) else { throw Abort(.internalServerError) }
        return post
    }

    static func createEventPost(
        authorID: String, communityID: String?, content: String?,
        eventTitle: String?, eventLocation: String?, eventStartsAt: String?, eventEndsAt: String?,
        hashtags: [String], mode: String?, privacy: String?,
        publishing: Publishing = .now,
        on db: AppDatabase
    ) async throws -> PostObject {
        let trimmedContent = content?.trimmedText ?? ""
        if trimmedContent.isEmpty { throw Abort(.badRequest, reason: "Post content is required") }
        if trimmedContent.count > 2000 { throw Abort(.badRequest, reason: "Post content must be at most 2000 characters") }
        let title = eventTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty { throw Abort(.badRequest, reason: "Event title is required") }
        guard let startsAtStr = eventStartsAt, !startsAtStr.isEmpty else { throw Abort(.badRequest, reason: "Event start time is required") }
        try validateMode(mode)
        guard let startsAt = JSONCoding.isoFractional.date(from: startsAtStr) ?? ISO8601DateFormatter().date(from: startsAtStr) else {
            throw Abort(.badRequest, reason: "Invalid event start time")
        }
        if let after = publishing.datesAfter, startsAt <= after {
            throw Abort(.badRequest, reason: publishing.publishAt == nil
                ? "Event start time must be in the future" : "Event must start after the post goes out")
        }
        if let endsStr = eventEndsAt?.nilIfEmpty,
           let endsAt = JSONCoding.isoFractional.date(from: endsStr) ?? ISO8601DateFormatter().date(from: endsStr),
           endsAt <= startsAt {
            throw Abort(.badRequest, reason: "Event must end after it starts")
        }
        if let communityID {
            guard try await CommunityMemberStore.membership(communityID, authorID, on: db.sql()) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to post")
            }
        }
        let id = try await createCommunityPostRow(
            content: trimmedContent, authorID: authorID, communityID: communityID, postType: "event",
            imageUrls: nil, linkUrl: nil, articleTitle: nil,
            hashtags: hashtags, mode: mode, privacy: privacy, publishing: publishing, on: db)
        try await EventStore.create(postID: id, title: title, location: eventLocation?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                                    startsAt: startsAtStr, endsAt: eventEndsAt?.nilIfEmpty, on: db.sql())
        if let communityID, publishing.isLive { try await CommunityMemberStore.incrementPostCount(communityID, 1, on: db.sql()) }
        guard let post = try await PostStore.findById(id, viewer: authorID, includeOwnUnpublished: !publishing.isLive, on: db.sql()) else { throw Abort(.internalServerError) }
        return post
    }

    static func createJobPost(
        authorID: String, communityID: String?, content: String?,
        jobTitle: String?, jobCompany: String?, jobLocation: String?,
        employmentType: String?, salaryRange: String?, applicationDeadline: String?,
        details: PostsController.CreateBody.JobDataIn? = nil,
        hashtags: [String], mode: String?, privacy: String?,
        publishing: Publishing = .now,
        on db: AppDatabase
    ) async throws -> PostObject {
        let trimmedContent = content?.trimmedText ?? ""
        if trimmedContent.isEmpty { throw Abort(.badRequest, reason: "Post content is required") }
        if trimmedContent.count > 2000 { throw Abort(.badRequest, reason: "Post content must be at most 2000 characters") }
        let title = jobTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty { throw Abort(.badRequest, reason: "Job title is required") }
        if let communityID {
            guard try await CommunityMemberStore.membership(communityID, authorID, on: db.sql()) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to post")
            }
        }
        // Job posts are a Work-mode-only concept. Enforced here, not just
        // hidden from the iOS composer's picker. Feed always passes an
        // explicit, pre-validated `mode`; community posts pass mode: nil and
        // let createCommunityPostRow's own SQL derive it from the community's
        // `type` column (mirrored here in Swift so this check runs before
        // that INSERT, the same way it does for the explicit-mode Feed path).
        let effectiveMode: String?
        if let mode {
            effectiveMode = mode
        } else if let communityID {
            struct CommunityType: Decodable { let type: String }
            let row = try await db.sql().raw("SELECT type FROM communities WHERE id = \(uuid: communityID)")
                .first(decoding: CommunityType.self)
            effectiveMode = row?.type == "work" ? "work" : "hobby"
        } else {
            effectiveMode = nil
        }
        guard effectiveMode == "work" else { throw Abort(.badRequest, reason: "Job posts are only available in Work mode") }
        let extra = try await JobStore.validateDetails(details, author: authorID, on: db.sql())
        // A deadline is a calendar day: it may fall on the day the post goes out.
        if let after = publishing.datesAfter, let deadline = applicationDeadline?.nilIfEmpty,
           let day = Self.dayFormatter.date(from: String(deadline.prefix(10))),
           day < Calendar(identifier: .gregorian).startOfDay(for: after) {
            throw Abort(.badRequest, reason: "Application deadline can't be before the post goes out")
        }
        let id = try await createCommunityPostRow(
            content: trimmedContent, authorID: authorID, communityID: communityID, postType: "job",
            imageUrls: nil, linkUrl: nil, articleTitle: nil,
            hashtags: hashtags, mode: mode, privacy: privacy, publishing: publishing, on: db)
        try await JobStore.create(postID: id, title: title,
            company: jobCompany?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            location: jobLocation?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            employmentType: employmentType?.nilIfEmpty, salaryRange: salaryRange?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            applicationDeadline: applicationDeadline?.nilIfEmpty, extra: extra, on: db.sql())
        if let communityID, publishing.isLive { try await CommunityMemberStore.incrementPostCount(communityID, 1, on: db.sql()) }
        guard let post = try await PostStore.findById(id, viewer: authorID, includeOwnUnpublished: !publishing.isLive, on: db.sql()) else { throw Abort(.internalServerError) }
        return post
    }

    /// A marketplace listing: a community post whose description is the
    /// text (optional) and whose photos are its images.
    /// A Marketplace listing (migration 073): its own public post in `mode`,
    /// also listed in up to 5 of the seller's communities. Returns the post
    /// and the communities it went live in (the rest wait for approval).
    static func createListingPost(
        authorID: String, mode: String, content: String?, imageUrls: [String]?,
        details: PostsController.CreateBody.ListingDataIn?, communityIDs: [String]?,
        on db: AppDatabase
    ) async throws -> (post: PostObject, liveIn: [String]) {
        let description = content?.trimmedText ?? ""
        if description.count > 2000 { throw Abort(.badRequest, reason: "Post content must be at most 2000 characters") }
        guard let photos = imageUrls, !photos.isEmpty else { throw Abort(.badRequest, reason: "Add at least one photo") }
        let listing = try ListingStore.validate(details)
        let ids = try ListingStore.communityIDs(communityIDs)
        let links = try await ListingStore.links(ids, seller: authorID, mode: mode, on: db.sql())
        let id = try await createCommunityPostRow(
            content: description, authorID: authorID, communityID: nil, postType: "listing",
            imageUrls: imageUrls, linkUrl: nil, articleTitle: nil,
            hashtags: [], mode: mode, privacy: "public", on: db)
        do {
            try await db.tx { t in
                let listingID = try await ListingStore.create(postID: id, listing, on: t)
                try await ListingStore.link(listingID: listingID, links, on: t)
            }
        } catch {
            // Without its details the post would be a bare listing; take it back out.
            try? await db.sql().raw("DELETE FROM posts WHERE id = \(uuid: id)").run()
            throw error
        }
        guard let post = try await PostStore.findById(id, viewer: authorID, on: db.sql()) else { throw Abort(.internalServerError) }
        return (post, links.filter { !$0.pending }.map(\.communityID))
    }

    // MARK: delete / restore

    static func deletePost(requesterID: String, postID: String, on db: AppDatabase) async throws {
        let sdb = db.sql()
        guard let meta = try await PostStore.findMeta(postID, on: sdb) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        let isAuthor = meta.author_id == requesterID
        var isStaff = false
        if let cid = meta.community_id {
            let role = try await CommunityMemberStore.membership(cid, requesterID, on: sdb)?.role
            isStaff = role == "admin" || role == "moderator"
        }
        guard isAuthor || isStaff else {
            throw Abort(.forbidden, reason: "You do not have permission to delete this post")
        }
        guard let deleted = try await PostStore.softDelete(postID, on: sdb) else {
            throw Abort(.notFound, reason: "Post not found or already deleted")
        }
        if let cid = deleted.community_id { try await CommunityMemberStore.incrementPostCount(cid, -1, on: sdb) }
    }

    static func restorePost(requesterID: String, postID: String, on db: AppDatabase) async throws -> PostObject {
        let sdb = db.sql()
        guard let meta = try await PostStore.findMeta(postID, on: sdb) else {
            throw Abort(.notFound, reason: "Post not found")
        }
        guard meta.author_id == requesterID else {
            throw Abort(.forbidden, reason: "You do not have permission to restore this post")
        }
        guard let restored = try await PostStore.restore(postID, requester: requesterID, on: sdb) else {
            throw Abort(.notFound, reason: "Post not found or not deleted")
        }
        if let cid = meta.community_id { try await CommunityMemberStore.incrementPostCount(cid, 1, on: sdb) }
        return restored
    }

    // MARK: vote / rsvp

    /// Votes for `optionID`, moves the vote there, or, with nil, takes it back.
    static func voteOnPoll(postID: String, userID: String, optionID: String?, on db: AppDatabase) async throws {
        let sdb = db.sql()
        guard let meta = try await PostStore.findMeta(postID, on: sdb) else { throw Abort(.notFound, reason: "Post not found") }
        guard meta.post_type == "poll" else { throw Abort(.badRequest, reason: "This post is not a poll") }
        if let cid = meta.community_id {
            guard try await CommunityMemberStore.membership(cid, userID, on: sdb) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to vote")
            }
        }
        if let optionID {
            let valid = try await PollStore.optionIDs(postID: postID, on: sdb)
            guard valid.contains(optionID.lowercased()) else { throw Abort(.badRequest, reason: "Invalid poll option for this post") }
        }
        try await PollStore.setVote(postID: postID, optionID: optionID, userID: userID, on: db)
    }

    static func rsvpEvent(eventID: String, userID: String, status: String?, on db: AppDatabase) async throws {
        guard let status, ["going", "maybe", "not_going"].contains(status) else {
            throw Abort(.badRequest, reason: "Status must be going, maybe, or not_going")
        }
        let sdb = db.sql()
        guard let event = try await EventStore.byID(eventID, on: sdb) else { throw Abort(.notFound, reason: "Event not found") }
        if let cid = event.community_id {
            guard try await CommunityMemberStore.membership(cid, userID, on: sdb) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to RSVP")
            }
        }
        try await EventStore.upsertRsvp(eventID: eventID, userID: userID, status: status, on: db)
    }

    static func interestInJob(jobID: String, userID: String, interested: Bool, on db: AppDatabase) async throws {
        let sdb = db.sql()
        guard let job = try await JobStore.byID(jobID, on: sdb) else { throw Abort(.notFound, reason: "Job post not found") }
        if let cid = job.community_id {
            guard try await CommunityMemberStore.membership(cid, userID, on: sdb) != nil else {
                throw Abort(.forbidden, reason: "You must be a member of this community to respond to this job post")
            }
        }
        try await JobStore.setInterested(jobID: jobID, userID: userID, interested: interested, on: db)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// User-written text (posts, comments, chat) without the spaces and line
    /// breaks before its first and after its last visible character. Only
    /// the edges: line breaks inside the text are kept.
    var trimmedText: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
