import Vapor
import Queues
import QueuesRedisDriver
import SQLKit

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
        try app.queues.use(.redis(url: "redis://\(r.host):\(r.port)"))

        app.queues.add(TagExtractionJob())
        app.queues.add(ChunkEmbedJob())

        // Daily housekeeping — staggered UTC slots, matching the Node crons.
        app.queues.schedule(AnalyticsSnapshotJob()).using(utc).daily().at(0, 5)
        app.queues.schedule(AgeRecomputeJob()).using(utc).daily().at(0, 10)
        app.queues.schedule(BirthdayJob()).using(utc).daily().at(0, 15)
        app.queues.schedule(PinExpiryJob()).using(utc).daily().at(0, 20)
        app.queues.schedule(PostPurgeJob()).using(utc).daily().at(0, 25)
        app.queues.schedule(DataCleanupJob()).using(utc).daily().at(0, 30)
        // Sub-daily.
        app.queues.schedule(TrendingJob()).using(utc).hourly().at(0)
        app.queues.schedule(ChunkSweepJob()).using(utc).hourly().at(15)
        app.queues.schedule(MeetingReminderJob()).every(minutes: 5)   // matches Node's */5 cron; atomic claim makes it idempotent

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

    // MARK: queue jobs (tag-extraction → chunk-embedding chain)

    struct TagExtractionJob: AsyncJob {
        struct Payload: Codable, Sendable { let postId: String; let content: String }
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            let app = context.application
            try await PostTagExtractService.extractAndSave(
                app.ollama, postID: payload.postId, content: payload.content,
                on: app.db.sql(), logger: context.logger)
            try await context.queue.dispatch(ChunkEmbedJob.self, .init(kind: .post, id: payload.postId), maxRetryCount: 3)
        }
    }

    struct ChunkEmbedJob: AsyncJob {
        enum Kind: String, Codable, Sendable { case post, profile }
        struct Payload: Codable, Sendable { let kind: Kind; let id: String }
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            let app = context.application
            switch payload.kind {
            case .post:    _ = try await ChunkService.buildPostChunk(payload.id, cfg: app.ollama, on: app.db.sql(), logger: context.logger)
            case .profile: _ = try await ChunkService.buildProfileChunk(payload.id, cfg: app.ollama, on: app.db.sql(), logger: context.logger)
            }
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
                  (SELECT COUNT(*) FROM posts WHERE community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')::int AS new_posts_24h,
                  (SELECT COUNT(*) FROM community_members WHERE community_id = \(uuid: c.id) AND joined_at >= NOW() - INTERVAL '24 hours')::int AS new_members_24h,
                  (SELECT COUNT(DISTINCT author_id) FROM posts WHERE community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')::int AS active_members_24h
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
                  (SELECT COUNT(*) FROM posts WHERE community_id = \(uuid: c.id)),
                  (SELECT COUNT(*) FROM community_members WHERE community_id = \(uuid: c.id) AND joined_at >= CURRENT_DATE),
                  (SELECT COUNT(*) FROM posts WHERE community_id = \(uuid: c.id) AND created_at >= CURRENT_DATE),
                  (SELECT COUNT(DISTINCT author_id) FROM posts WHERE community_id = \(uuid: c.id) AND created_at >= NOW() - INTERVAL '24 hours')
                ON CONFLICT (community_id, snapshot_date) DO UPDATE SET
                  member_count = EXCLUDED.member_count, post_count = EXCLUDED.post_count,
                  new_members = EXCLUDED.new_members, new_posts = EXCLUDED.new_posts,
                  active_members = EXCLUDED.active_members
                """).run()
        }
    }

    /// Enqueue embed jobs for posts/users missing their chunk; delete orphan
    /// post chunks. Runs hourly + once at boot.
    static func chunkSweep(_ app: Application) async throws {
        let db = app.db.sql()
        let batch = 100
        struct I: Decodable { let id: String }
        let pendingPosts = try await db.raw("""
            SELECT p.id::text AS id FROM posts p
            WHERE p.status = 'posted'
              AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c WHERE c.source_type = 'post' AND c.source_id = p.id)
            ORDER BY p.created_at DESC LIMIT \(unsafeRaw: String(batch))
            """).all(decoding: I.self)
        let pendingUsers = try await db.raw("""
            SELECT u.id::text AS id FROM users u
            WHERE u.deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c WHERE c.user_id = u.id AND c.source_type = 'user_profile')
            LIMIT \(unsafeRaw: String(batch))
            """).all(decoding: I.self)
        try await db.raw("""
            DELETE FROM user_embedding_chunks c
            WHERE c.source_type = 'post'
              AND NOT EXISTS (SELECT 1 FROM posts p WHERE p.id = c.source_id AND p.status = 'posted')
            """).run()
        for p in pendingPosts {
            try? await app.queues.queue.dispatch(ChunkEmbedJob.self, .init(kind: .post, id: p.id), maxRetryCount: 3)
        }
        for u in pendingUsers {
            try? await app.queues.queue.dispatch(ChunkEmbedJob.self, .init(kind: .profile, id: u.id), maxRetryCount: 3)
        }
        if !pendingPosts.isEmpty || !pendingUsers.isEmpty {
            app.logger.info("chunkSweep: enqueued \(pendingPosts.count) posts, \(pendingUsers.count) profiles")
        }
    }
}
