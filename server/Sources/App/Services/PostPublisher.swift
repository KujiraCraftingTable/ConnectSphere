import Vapor
import Queues
import SQLKit

/// What happens when a post goes live. At once, or later from a schedule.
/// Kept in one place so a scheduled post gets exactly what an immediate one does.
enum PostPublisher {
    /// A post that just went live, as `claimScheduled` / `publishNow` return it.
    struct Live: Decodable {
        let id: String
        let author_id: String
        let community_id: String?
        let post_type: String
        let mode: String
        let content: String?
        /// posted, or pending, when its community approves posts first.
        let status: String
    }

    /// The status a post takes when it goes out: `pending` in a community
    /// that approves posts (unless the author is staff there), or for a new
    /// HR's job still in its trial (migration 126), else `posted`.
    static let goingOutStatus = """
        CASE WHEN posts.post_type = 'job'
               AND EXISTS (SELECT 1 FROM recruiters r WHERE r.user_id = posts.author_id AND r.trial_left > 0)
             THEN 'pending'::post_status
             WHEN posts.community_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM communities c WHERE c.id = posts.community_id AND c.require_post_approval)
               AND NOT EXISTS (SELECT 1 FROM community_members m WHERE m.community_id = posts.community_id
                                 AND m.user_id = posts.author_id AND m.role IN ('admin', 'moderator'))
             THEN 'pending'::post_status ELSE 'posted'::post_status END
        """

    /// For feed posts (community posts don't have these yet): the AI mode
    /// check, which notifies the author on a mismatch, and tag extraction →
    /// embedding (or a direct embed for a link/image-only post). The queue
    /// part only when this server owns the job schedule.
    static func afterPublish(_ req: Request, post: PostObject) async {
        await afterPublish(req.application, queue: BackgroundJobs.queue(for: req), logger: req.logger,
                           postID: post.id, mode: post.mode, content: post.content ?? "", authorID: req.userID)
    }

    static func afterPublish(_ app: Application, queue: (any Queue)?, logger: Logger,
                             postID: String, mode: String, content: String, authorID: String) async {
        await TranslationService.enqueue(.post, id: postID, app: app, queue: queue, logger: logger)
        await ModerationScan.enqueue(app, queue: queue, logger: logger, .post, id: postID)
        if !content.isEmpty {
            let cfg = app.ollama, db = app.db.sql(), hub = app.socketHub
            // Background priority: nobody is waiting on this check, and the
            // gate runs one such call at a time.
            Task {
                let r = await OllamaGate.$isBackground.withValue(true) {
                    await PostAnalyzeService.analyze(cfg, content, logger: logger)
                }
                if r.confidence >= 0.75, r.suggestedMode != "neutral", r.suggestedMode != mode {
                    _ = await NotifyService.pushUserNotification(userID: authorID, type: "mode_mismatch",
                        postID: postID,
                        payload: ["suggestedMode": r.suggestedMode, "currentMode": mode, "reason": r.reason],
                        on: db, hub: hub, logger: logger)
                }
            }
        }
        if let queue {
            if !content.isEmpty {
                try? await queue.dispatch(BackgroundJobs.TagExtractionJob.self,
                    .init(postId: postID, content: content), maxRetryCount: 3)
            } else {
                try? await queue.dispatch(BackgroundJobs.ChunkEmbedJob.self,
                    .init(kind: .post, id: postID), maxRetryCount: 3)
            }
        }
    }

    // MARK: scheduled posts

    static let minLead: TimeInterval = 5 * 60
    static let maxLead: TimeInterval = 180 * 86_400

    /// A schedule time is between 5 minutes and 180 days from `now`.
    static func validScheduleTime(_ date: Date, now: Date = Date()) -> Bool {
        date >= now.addingTimeInterval(minLead) && date <= now.addingTimeInterval(maxLead)
    }

    /// Claims every scheduled post that's due, atomically. Two job runs (or
    /// two servers) can't both publish one. It takes its publish time as its
    /// date, so it lands in feeds as new.
    static func claimScheduled(on db: any SQLDatabase) async throws -> [Live] {
        try await db.raw("""
            UPDATE posts SET status = \(unsafeRaw: goingOutStatus), created_at = COALESCE(publish_at, NOW()), publish_at = NULL
            WHERE status = 'scheduled' AND publish_at <= NOW()
            RETURNING id::text AS id, author_id::text AS author_id, community_id::text AS community_id,
                      post_type, mode, content, status::text AS status
            """).all(decoding: Live.self)
    }

    /// "Publish now" on one of your scheduled posts.
    static func publishNow(_ id: String, author: String, on db: any SQLDatabase) async throws -> Live? {
        try await db.raw("""
            UPDATE posts SET status = \(unsafeRaw: goingOutStatus), created_at = NOW(), publish_at = NULL
            WHERE id = \(uuid: id) AND author_id = \(uuid: author) AND status = 'scheduled'
            RETURNING id::text AS id, author_id::text AS author_id, community_id::text AS community_id,
                      post_type, mode, content, status::text AS status
            """).first(decoding: Live.self)
    }

    /// The counters a post bumps when it's created live, plus the feed side
    /// effects and, for a scheduled one, "Your scheduled post is live".
    static func didGoLive(_ post: Live, app: Application, queue: (any Queue)?, logger: Logger, notify: Bool) async {
        // Held for approval: nothing is live yet. Approving it does the rest.
        guard post.status == "posted" else { return }
        let db = app.db.sql()
        do {
            if let community = post.community_id {
                try await CommunityMemberStore.incrementPostCount(community, 1, on: db)
            } else if post.post_type == "text" {
                try await db.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: post.author_id)").run()
            }
        } catch {
            logger.warning("PostPublisher: counters for \(post.id) failed: \(error)")
        }
        if post.community_id == nil {
            await afterPublish(app, queue: queue, logger: logger, postID: post.id, mode: post.mode,
                               content: post.content ?? "", authorID: post.author_id)
        } else {
            await TranslationService.enqueue(.post, id: post.id, app: app, queue: queue, logger: logger)
            await ModerationScan.enqueue(app, queue: queue, logger: logger, .post, id: post.id)
            if let community = post.community_id {
                NotifyService.communityNewPost(app: app, postID: post.id, communityID: community,
                                               authorID: post.author_id, logger: logger)
            }
        }
        if notify {
            _ = await NotifyService.pushUserNotification(userID: post.author_id, type: "scheduled_post_live",
                postID: post.id, payload: [:], on: db, hub: app.socketHub, logger: logger)
        }
    }

    /// Something in the post that has gone stale while it waited (a poll that
    /// already ended, an event that already started), or nil.
    static func staleDates(_ id: String, on db: any SQLDatabase) async throws -> String? {
        struct R: Decodable { let poll_over: Bool; let event_started: Bool }
        let r = try await db.raw("""
            SELECT EXISTS (SELECT 1 FROM poll_options WHERE post_id = \(uuid: id) AND ends_at <= NOW()) AS poll_over,
                   EXISTS (SELECT 1 FROM community_events WHERE post_id = \(uuid: id) AND starts_at <= NOW()) AS event_started
            """).first(decoding: R.self)
        if r?.poll_over == true { return "Poll end date must be in the future" }
        if r?.event_started == true { return "Event start time must be in the future" }
        return nil
    }
}
