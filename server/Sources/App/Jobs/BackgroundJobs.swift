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
        app.queues.schedule(PinExpiryJob()).using(utc).daily().at(0, 20)
        app.queues.schedule(PostPurgeJob()).using(utc).daily().at(0, 25)
        app.queues.schedule(DataCleanupJob()).using(utc).daily().at(0, 30)
        // Hourly.
        app.queues.schedule(TrendingJob()).using(utc).hourly().at(0)
        app.queues.schedule(ChunkSweepJob()).using(utc).hourly().at(15)

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
