import Vapor
import Queues
import QueuesRedisDriver
import SQLKit
import NIOConcurrencyHelpers

/// Port of `backend/src/jobs/*` + `queues/*`. BullMQ → Vapor Queues.
///
/// Gated behind `RUN_JOBS=1` — during the parallel-oracle phase the Node
/// backend owns the schedule; the Swift server only runs jobs once it is the
/// primary (Phase 6 cutover sets the flag).
enum BackgroundJobs {
    static var enabled: Bool { Environment.get("RUN_JOBS") == "1" }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Wire the Redis driver, register job handlers + the schedule. Call from
    /// `configure` only when `enabled`.
    static func register(_ app: Application) throws {
        let r = app.appEnv.redis
        // Vapor's default pool holds 2 connections and waits only 10 ms for a
        // free one (nil `connectionRetryTimeout` → RediStack's floor), while
        // Queues starts a worker per CPU core. Workers starved, logging
        // `timedOutWaitingForConnection` every few seconds — and one that
        // failed after popping a job lost that job.
        let redis = try RedisConfiguration(url: "redis://\(r.host):\(r.port)", pool: .init(
            maximumConnectionCount: .maximumActiveConnections(4),
            connectionRetryTimeout: .seconds(5)))
        app.queues.use(.redis(redis))
        // Embedding jobs all funnel into the one local Ollama; more workers
        // would only contend for connections.
        app.queues.configuration.workerCount = .custom(2)

        app.queues.add(TagExtractionJob())
        app.queues.add(ChunkEmbedJob())
        app.queues.add(SocialNotifyJob())

        // Daily housekeeping — staggered UTC slots, matching the Node crons.
        app.queues.schedule(AnalyticsSnapshotJob()).using(utc).daily().at(0, 5)
        app.queues.schedule(AgeRecomputeJob()).using(utc).daily().at(0, 10)
        app.queues.schedule(BirthdayJob()).using(utc).daily().at(0, 15)
        app.queues.schedule(PinExpiryJob()).using(utc).daily().at(0, 20)
        app.queues.schedule(PostPurgeJob()).using(utc).daily().at(0, 25)
        app.queues.schedule(DataCleanupJob()).using(utc).daily().at(0, 30)
        // Sub-daily.
        app.queues.schedule(TrendingJob()).using(utc).hourly().at(0)
        // Safety net for the 6-hour freshness promise (see `chunkSweep`).
        app.queues.schedule(ChunkSweepJob()).every(minutes: 30)
        app.queues.schedule(MeetingReminderJob()).every(minutes: 5)   // matches Node's */5 cron; atomic claim makes it idempotent
        app.queues.schedule(PublishScheduledJob()).every(minutes: 1)   // scheduled posts go out within a minute

        try app.queues.startInProcessJobs(on: .default)
        try app.queues.startScheduledJobs()

        // chunkSweep also runs once at boot (backfill after a fresh DB).
        Task { try? await chunkSweep(app) }
    }

    // MARK: scheduled jobs

    struct AgeRecomputeJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            try await context.application.db.sql().raw("""
                UPDATE users SET age = EXTRACT(YEAR FROM AGE(dob))::int
                WHERE dob IS NOT NULL AND age IS DISTINCT FROM EXTRACT(YEAR FROM AGE(dob))::int
                """).run()
        }
    }

    struct PinExpiryJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            struct R: Decodable { let conversation_id: String; let message_id: String }
            let deleted = try await context.application.db.sql().raw("""
                DELETE FROM message_pins WHERE expires_at IS NOT NULL AND expires_at <= NOW()
                RETURNING conversation_id::text AS conversation_id, message_id::text AS message_id
                """).all(decoding: R.self)
            for d in deleted {
                context.application.socketHub.emit(room: d.conversation_id, event: "pin_removed",
                    WSPinRemoved(conversation_id: d.conversation_id, message_id: d.message_id))
            }
            if !deleted.isEmpty { context.logger.info("PinExpiryJob: removed \(deleted.count) expired pins") }
        }
    }

    struct PostPurgeJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            let db = context.application.db.sql()
            try await db.raw("DELETE FROM posts WHERE status = 'deleted' AND deleted_at < NOW() - INTERVAL '30 days'").run()
            try await db.raw("DELETE FROM comments WHERE status = 'deleted' AND deleted_at < NOW() - INTERVAL '30 days'").run()
        }
    }

    struct DataCleanupJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            let db = context.application.db.sql()
            try await db.raw("DELETE FROM stories WHERE expires_at < NOW()").run()
            try await db.raw("""
                DELETE FROM password_resets
                WHERE (used_at IS NOT NULL OR expires_at < NOW()) AND created_at < NOW() - INTERVAL '7 days'
                """).run()
            try await db.raw("DELETE FROM search_logs WHERE created_at < NOW() - INTERVAL '90 days'").run()
        }
    }

    struct TrendingJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws { try await computeAllTrendingScores(context.application) }
    }

    struct AnalyticsSnapshotJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws { try await recordAllSnapshots(context.application) }
    }

    struct ChunkSweepJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws { try await chunkSweep(context.application) }
    }

    /// Daily birthday greetings — notify each birthday user's accepted
    /// connections, deduped against "already sent today".
    struct BirthdayJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            let app = context.application, db = app.db.sql()
            struct I: Decodable { let id: String }
            let birthdayUsers = try await db.raw("""
                SELECT id::text AS id FROM users
                WHERE dob IS NOT NULL AND deleted_at IS NULL
                  AND EXTRACT(MONTH FROM dob) = EXTRACT(MONTH FROM CURRENT_DATE)
                  AND EXTRACT(DAY FROM dob) = EXTRACT(DAY FROM CURRENT_DATE)
                """).all(decoding: I.self)
            for bu in birthdayUsers {
                let connections = try await db.raw("""
                    SELECT DISTINCT (CASE WHEN c.requester_id = \(uuid: bu.id) THEN c.addressee_id ELSE c.requester_id END)::text AS id
                    FROM connections c WHERE c.status = 'accepted'
                      AND (c.requester_id = \(uuid: bu.id) OR c.addressee_id = \(uuid: bu.id))
                    """).all(decoding: I.self).map(\.id)
                for cid in connections {
                    struct One: Decodable { let one: Int }
                    let already = try await db.raw("""
                        SELECT 1 AS one FROM user_notifications
                        WHERE user_id = \(uuid: cid) AND type = 'birthday'
                          AND payload->>'fromUserId' = \(bind: bu.id) AND created_at::date = CURRENT_DATE LIMIT 1
                        """).first(decoding: One.self) != nil
                    if already { continue }
                    _ = await NotifyService.pushUserNotification(userID: cid, type: "birthday", actorID: bu.id,
                        on: db, hub: app.socketHub, logger: context.logger)
                }
            }
        }
    }

    /// Every 5 min — send due meeting reminders. Folded review fix: claim the
    /// due rows atomically (`UPDATE … reminder_sent_at = NOW() WHERE … IS NULL
    /// RETURNING id`) BEFORE sending, so a concurrent/overlapping run can't
    /// double-send.
    struct MeetingReminderJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            let app = context.application, db = app.db.sql()
            struct Due: Decodable {
                let id: String; let title: String; let starts_at: Date
                let message_id: String; let conversation_id: String
            }
            let claimed = try await db.raw("""
                WITH due AS (
                  SELECT mp.id FROM message_meeting_proposals mp
                  WHERE mp.status = 'active' AND mp.reminder_sent_at IS NULL AND mp.reminder_at <= NOW()
                ),
                claimed AS (
                  UPDATE message_meeting_proposals SET reminder_sent_at = NOW()
                  WHERE id IN (SELECT id FROM due) AND reminder_sent_at IS NULL
                  RETURNING id
                )
                SELECT mp.id::text AS id, mp.title, mp.starts_at,
                       m.id::text AS message_id, m.conversation_id::text AS conversation_id
                FROM claimed c JOIN message_meeting_proposals mp ON mp.id = c.id
                JOIN messages m ON m.id = mp.message_id
                """).all(decoding: Due.self)
            for p in claimed {
                guard let conv = try await ChatStore.conversationByID(p.conversation_id, on: db) else { continue }
                let recipients: [String]
                if conv.is_group {
                    struct U: Decodable { let user_id: String }
                    recipients = try await db.raw("SELECT user_id::text AS user_id FROM message_meeting_rsvps WHERE proposal_id = \(uuid: p.id) AND status = 'going'")
                        .all(decoding: U.self).map(\.user_id)
                } else {
                    recipients = try await ChatStore.participants(p.conversation_id, on: db)
                }
                for uid in recipients {
                    _ = await NotifyService.pushUserNotification(userID: uid, type: "meeting_reminder",
                        conversationID: p.conversation_id, entityID: p.id,
                        payload: ["conversationId": p.conversation_id, "messageId": p.message_id,
                                  "proposalId": p.id, "title": p.title,
                                  "startsAt": JSONCoding.isoFractional.string(from: p.starts_at)],
                        on: db, hub: app.socketHub, logger: context.logger)
                }
            }
            if !claimed.isEmpty { context.logger.info("MeetingReminderJob: \(claimed.count) reminders sent") }
        }
    }

    /// Publishes scheduled posts that are due (claimed atomically, so it's
    /// safe to overlap) and tells each author theirs is live. Anything due
    /// while the server was down goes out on the first run after.
    struct PublishScheduledJob: AsyncScheduledJob {
        func run(context: QueueContext) async throws {
            let app = context.application
            let live = try await PostPublisher.claimScheduled(on: app.db.sql())
            for post in live {
                await PostPublisher.didGoLive(post, app: app, queue: context.queue, logger: context.logger, notify: true)
            }
            if !live.isEmpty { context.logger.info("PublishScheduledJob: \(live.count) scheduled post(s) published") }
        }
    }

    // MARK: queue jobs (tag-extraction → chunk-embedding chain)

    struct TagExtractionJob: AsyncJob {
        struct Payload: Codable, Sendable { let postId: String; let content: String }
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            let app = context.application
            try await PostTagExtractService.extractAndSave(
                app.ollama, postID: payload.postId, content: payload.content,
                client: app.http.client.shared, on: app.db.sql(), logger: context.logger)
            try await context.queue.dispatch(ChunkEmbedJob.self, .init(kind: .post, id: payload.postId), maxRetryCount: 3)
        }
    }

    struct ChunkEmbedJob: AsyncJob {
        enum Kind: String, Codable, Sendable { case post, profile }
        struct Payload: Codable, Sendable { let kind: Kind; let id: String }
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            _ = try await Self.build(payload.kind, id: payload.id, app: context.application, logger: context.logger)
        }

        /// Also called directly by `chunkSweep` when the queue isn't getting through.
        static func build(_ kind: Kind, id: String, app: Application, logger: Logger) async throws -> Bool {
            switch kind {
            case .post:    return try await ChunkService.buildPostChunk(id, cfg: app.ollama, on: app.db.sql(), logger: logger)
            case .profile: return try await ChunkService.buildProfileChunk(id, cfg: app.ollama, on: app.db.sql(), logger: logger)
            }
        }
    }

    // MARK: embedding refresh on edit

    /// A post's or profile's text just changed: re-embed now instead of waiting
    /// for the sweep. Never fails the request — a failed dispatch is caught by
    /// the next sweep. Calling it when nothing relevant changed is cheap: the
    /// build sees the same source hash and stops before any LLM call.
    static func refreshEmbedding(_ req: Request, _ kind: ChunkEmbedJob.Kind, id: String) async {
        guard enabled else { return }
        try? await req.queue.dispatch(ChunkEmbedJob.self, .init(kind: kind, id: id), maxRetryCount: 3)
    }

    /// A post's content was edited. Its AI tags described the old text and are
    /// part of what gets embedded, so drop them and re-extract — extraction
    /// chains into the re-embed.
    static func refreshPostAfterContentEdit(_ req: Request, postID: String, content: String) async {
        guard enabled else { return }
        try? await req.db.sql().raw("DELETE FROM post_tags WHERE post_id = \(uuid: postID) AND source = 'ai'").run()
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            await refreshEmbedding(req, .post, id: postID)
        } else {
            try? await req.queue.dispatch(TagExtractionJob.self, .init(postId: postID, content: content), maxRetryCount: 3)
        }
    }

    // MARK: social notifications (like / comment / reply / comment-like / share / connect)

    /// Delivers a "someone interacted with your thing" notification, but only
    /// after a ~3s delay (see `NotifyService.dispatchSocial`) — long enough that
    /// an accidental like / comment / connection request undone within the
    /// window never reaches the recipient. `dequeue` re-checks that the
    /// triggering state still holds, then applies a 24h unread-dup guard, then
    /// writes the row through `NotifyService.pushUserNotification`.
    ///
    /// `groupTargetID` / `entityID` per type match the retired Node backend so
    /// the read side groups these rows identically:
    ///   post_liked      → group `post_liked:<postID>`,       entity = post
    ///   comment_liked   → group `comment_liked:<commentID>`, entity = comment
    ///   post_commented  → group `post_commented:<postID>`,   entity = comment
    ///   comment_replied → group `comment_replied:<parentID>`,entity = comment
    ///   post_shared     → group `post_shared:<rootPostID>`,  entity = post
    ///   connection_*    → group `<type>:none`,               entity = none
    struct SocialNotifyJob: AsyncJob {
        struct Payload: Codable, Sendable {
            var type: String
            var actorID: String
            var recipientID: String
            var postID: String? = nil
            var commentID: String? = nil
            var parentCommentID: String? = nil
            var connectionID: String? = nil
            /// For post_shared: the repost row's id — deleting it inside the
            /// delay window cancels the notification.
            var checkID: String? = nil
        }

        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            await Self.deliver(payload, on: context.application.db.sql(),
                               hub: context.application.socketHub, logger: context.logger)
        }

        /// Shared body so the jobs-off fallback path (`dispatchSocial` when
        /// `RUN_JOBS` is unset) can reuse it verbatim.
        static func deliver(_ p: Payload, on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
            guard p.actorID != p.recipientID else { return }
            do {
                guard try await stillValid(p, on: db) else {
                    logger.debug("SocialNotifyJob \(p.type): triggering state gone, skipping")
                    return
                }

                let entityID: String?
                let groupTargetID: String?
                switch p.type {
                case "post_liked":      entityID = p.postID;    groupTargetID = p.postID
                case "comment_liked":   entityID = p.commentID; groupTargetID = p.commentID
                case "post_commented":  entityID = p.commentID; groupTargetID = p.postID
                case "comment_replied": entityID = p.commentID; groupTargetID = p.parentCommentID
                case "post_shared":     entityID = p.postID;    groupTargetID = nil
                default:                entityID = nil;         groupTargetID = nil   // connection_*
                }

                // Same formula pushUserNotification uses internally → the dup
                // check and the eventual INSERT can't drift onto different keys.
                let refs = NotifyService.resolveRefs(
                    type: p.type, entityType: nil, entityID: entityID, groupTargetID: groupTargetID,
                    postID: p.postID, conversationID: nil, communityID: nil)

                struct One: Decodable { let one: Int }
                let dup = try await db.raw("""
                    SELECT 1 AS one FROM user_notifications
                    WHERE user_id = \(uuid: p.recipientID) AND group_key = \(bind: refs.groupKey)
                      AND actor_id IS NOT DISTINCT FROM \(uuid: p.actorID)
                      AND is_read = FALSE AND created_at > NOW() - INTERVAL '24 hours'
                    LIMIT 1
                    """).first(decoding: One.self) != nil
                if dup {
                    logger.debug("SocialNotifyJob \(p.type): unread duplicate within 24h, skipping")
                    return
                }

                var payload: [String: Any] = [:]
                if p.type == "post_commented" || p.type == "comment_replied" {
                    if let ex = try await commentExcerpt(p.commentID, on: db) { payload["excerpt"] = ex }
                    if let cid = p.commentID { payload["commentId"] = cid }
                    if let par = p.parentCommentID { payload["parentCommentId"] = par }
                }

                _ = await NotifyService.pushUserNotification(
                    userID: p.recipientID, type: p.type, actorID: p.actorID,
                    postID: p.postID, entityID: entityID, groupTargetID: groupTargetID,
                    payload: payload, on: db, hub: hub, logger: logger)
            } catch {
                logger.warning("SocialNotifyJob \(p.type) failed: \(error)")
            }
        }

        /// Has the interaction that triggered this notification survived the
        /// delay window? (like still there, comment/post still 'posted',
        /// connection still in the expected status)
        private static func stillValid(_ p: Payload, on db: any SQLDatabase) async throws -> Bool {
            struct One: Decodable { let one: Int }
            switch p.type {
            case "post_liked":
                guard let post = p.postID else { return false }
                return try await db.raw("SELECT 1 AS one FROM post_likes WHERE post_id = \(uuid: post) AND user_id = \(uuid: p.actorID)")
                    .first(decoding: One.self) != nil
            case "comment_liked":
                guard let c = p.commentID else { return false }
                return try await db.raw("SELECT 1 AS one FROM comment_likes WHERE comment_id = \(uuid: c) AND user_id = \(uuid: p.actorID)")
                    .first(decoding: One.self) != nil
            case "post_commented", "comment_replied":
                guard let c = p.commentID else { return false }
                return try await db.raw("SELECT 1 AS one FROM comments WHERE id = \(uuid: c) AND status = 'posted'")
                    .first(decoding: One.self) != nil
            case "post_shared":
                guard let repost = p.checkID ?? p.postID else { return false }
                return try await db.raw("SELECT 1 AS one FROM posts WHERE id = \(uuid: repost) AND status = 'posted'")
                    .first(decoding: One.self) != nil
            case "connection_request":
                guard let c = p.connectionID else { return false }
                return try await db.raw("SELECT 1 AS one FROM connections WHERE id = \(uuid: c) AND status = 'pending'")
                    .first(decoding: One.self) != nil
            case "connection_accepted":
                guard let c = p.connectionID else { return false }
                return try await db.raw("SELECT 1 AS one FROM connections WHERE id = \(uuid: c) AND status = 'accepted'")
                    .first(decoding: One.self) != nil
            default:
                return false
            }
        }

        private static func commentExcerpt(_ commentID: String?, on db: any SQLDatabase) async throws -> String? {
            guard let commentID else { return nil }
            struct R: Decodable { let content: String? }
            let content = try await db.raw("SELECT content FROM comments WHERE id = \(uuid: commentID) AND status = 'posted'")
                .first(decoding: R.self)?.content ?? nil
            guard let content, !content.isEmpty else { return nil }
            return String(content.prefix(120))
        }
    }

    // MARK: shared job bodies

    static func computeAllTrendingScores(_ app: Application) async throws {
        let db = app.db.sql()
        struct I: Decodable { let id: String }
        let ids = try await db.raw("SELECT id::text AS id FROM communities").all(decoding: I.self)
        for c in ids {
            struct S: Decodable { let new_posts_24h: Int; let new_members_24h: Int; let active_members_24h: Int }
            guard let s = try? await db.raw("""
                SELECT
                  (SELECT COUNT(*) FROM posts WHERE status = 'posted' AND community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')::int AS new_posts_24h,
                  (SELECT COUNT(*) FROM community_members WHERE community_id = \(uuid: c.id) AND joined_at >= NOW() - INTERVAL '24 hours')::int AS new_members_24h,
                  (SELECT COUNT(DISTINCT author_id) FROM posts WHERE status = 'posted' AND community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')::int AS active_members_24h
                """).first(decoding: S.self) else { continue }
            let score = s.new_posts_24h * 3 + s.new_members_24h * 5 + s.active_members_24h * 2
            try? await db.raw("""
                INSERT INTO community_trending (community_id, score, computed_at) VALUES (\(uuid: c.id), \(bind: score), NOW())
                ON CONFLICT (community_id) DO UPDATE SET score = \(bind: score), computed_at = NOW()
                """).run()
        }
    }

    static func recordAllSnapshots(_ app: Application) async throws {
        let db = app.db.sql()
        struct I: Decodable { let id: String }
        let ids = try await db.raw("SELECT id::text AS id FROM communities").all(decoding: I.self)
        for c in ids {
            try? await db.raw("""
                INSERT INTO community_analytics
                  (community_id, snapshot_date, member_count, post_count, new_members, new_posts, active_members)
                SELECT \(uuid: c.id), CURRENT_DATE,
                  (SELECT COUNT(*) FROM community_members WHERE community_id = \(uuid: c.id)),
                  (SELECT COUNT(*) FROM posts WHERE status = 'posted' AND community_id = \(uuid: c.id)),
                  (SELECT COUNT(*) FROM community_members WHERE community_id = \(uuid: c.id) AND joined_at >= CURRENT_DATE),
                  (SELECT COUNT(*) FROM posts WHERE status = 'posted' AND community_id = \(uuid: c.id) AND created_at >= CURRENT_DATE),
                  (SELECT COUNT(DISTINCT author_id) FROM posts WHERE status = 'posted' AND community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')
                ON CONFLICT (community_id, snapshot_date) DO UPDATE SET
                  member_count = EXCLUDED.member_count, post_count = EXCLUDED.post_count,
                  new_members = EXCLUDED.new_members, new_posts = EXCLUDED.new_posts,
                  active_members = EXCLUDED.active_members
                """).run()
        }
    }

    /// The freshness promise: a change to a post's or profile's text is
    /// embedded within this many hours.
    static let freshnessDeadlineHours = 6
    /// An out-of-date item still waiting after this long means the queue path
    /// is failing (Redis down, job lost) — the sweep then builds it itself.
    static let directBuildAfter: TimeInterval = 60 * 60

    private static let sweepRunning = NIOLockedValueBox(false)

    /// Reconciles every embedding with its source (every 30 min + at boot):
    /// drops chunks whose source is gone or emptied, queues everything out of
    /// date (no batch cap — the hash makes duplicate jobs free), and builds
    /// directly anything the queue hasn't managed within an hour. Items are
    /// tracked in `embedding_backlog`; one still pending past the deadline is
    /// logged as an error.
    static func chunkSweep(_ app: Application) async throws {
        // A long direct-build pass can outlast the interval; never overlap.
        let claimed = sweepRunning.withLockedValue { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard claimed else { return }
        defer { sweepRunning.withLockedValue { $0 = false } }

        let db = app.db.sql()
        try await db.raw("""
            DELETE FROM user_embedding_chunks c
            WHERE (c.source_type = 'post' AND post_embed_source_hash(c.source_id) IS NULL)
               OR (c.source_type = 'user_profile' AND profile_embed_source_hash(c.user_id) IS NULL)
            """).run()
        try await db.raw("""
            DELETE FROM embedding_backlog b
            WHERE NOT EXISTS (SELECT 1 FROM embedding_out_of_date o
                              WHERE o.source_type = b.source_type AND o.source_id = b.source_id)
            """).run()
        try await db.raw("""
            INSERT INTO embedding_backlog (source_type, source_id)
            SELECT source_type, source_id FROM embedding_out_of_date
            ON CONFLICT DO NOTHING
            """).run()
        struct Item: Decodable { let source_type: String; let source_id: String; let waited: Double }
        let items = try await db.raw("""
            SELECT source_type, source_id::text AS source_id,
                   EXTRACT(EPOCH FROM NOW() - first_seen_at)::float8 AS waited
            FROM embedding_backlog ORDER BY first_seen_at
            """).all(decoding: Item.self)
        guard !items.isEmpty else { return }

        let deadline = TimeInterval(freshnessDeadlineHours * 3600)
        let overdue = items.filter { $0.waited >= deadline }.count
        if overdue > 0 {
            app.logger.error("""
                chunkSweep: \(overdue) embedding(s) out of date for over \(freshnessDeadlineHours)h. \
                Building needs Ollama at \(app.appEnv.ollama.url); queued builds also need Redis.
                """)
        }

        var queued = 0, built = 0
        for item in items {
            let kind: ChunkEmbedJob.Kind = item.source_type == "post" ? .post : .profile
            if item.waited < directBuildAfter {
                do {
                    try await app.queues.queue.dispatch(ChunkEmbedJob.self, .init(kind: kind, id: item.source_id), maxRetryCount: 3)
                    queued += 1
                    continue
                } catch {
                    app.logger.warning("chunkSweep: queue unavailable (\(error)); building directly")
                }
            }
            if (try? await ChunkEmbedJob.build(kind, id: item.source_id, app: app, logger: app.logger)) == true {
                built += 1
            }
        }
        app.logger.info("chunkSweep: \(items.count) out of date — queued \(queued), built \(built) directly")
    }
}
