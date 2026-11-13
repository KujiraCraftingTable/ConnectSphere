import Vapor
import SQLKit
import Queues
import Crypto

/// Photo checks (migration 090). Every upload gets a row and, with an OpenAI
/// key, a background scan of the file itself. The verdict belongs to the file,
/// so content that uses it — a post, comment, story, profile photo — is judged when the scan lands *and* when the content is published,
/// whichever comes second. Chat photos are never scanned.
enum MediaScan {
    enum Status: String, Sendable { case pending, clean, flagged, unscanned }

    // MARK: deciding

    /// What OpenAI's answer means for the file. The scores are kept either way.
    static func decide(_ r: OpenAIModeration.Result) -> (status: Status, policy: ModerationPolicy?) {
        let policy = r.flagged ? ModerationScan.worst(r.categories.compactMap(OpenAIModeration.policy(for:))) : nil
        guard let policy else { return (.clean, nil) }
        return (.flagged, policy)
    }

    static func mime(forPath path: String) -> String? {
        switch path.lowercased().split(separator: ".").last {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "webp": "image/webp"
        default: nil   // heic/heif, video: OpenAI can't read them
        }
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: at upload

    /// Notes a stored upload. Returns false when the same file was removed by a
    /// moderator before (the caller deletes it and refuses the upload).
    static func isBanned(sha256: String, on db: any SQLDatabase) async throws -> Bool {
        struct X: Decodable { let x: Int }
        return try await db.raw("SELECT 1 AS x FROM banned_media WHERE sha256 = \(bind: sha256)").first(decoding: X.self) != nil
    }

    /// Records the file and queues the scan. `scannable` is false for videos,
    /// formats OpenAI can't read, and when no key is set: those are 'unscanned'.
    static func record(path: String, sha256: String, app: Application, queue: (any Queue)?, logger: Logger) async {
        let scannable = mime(forPath: path) != nil && !app.appEnv.moderation.openAIKey.isEmpty
        let status: Status = scannable ? .pending : .unscanned
        do {
            try await app.db.sql().raw("""
                INSERT INTO media_scans (path, sha256, status) VALUES (\(bind: path), \(bind: sha256), \(bind: status.rawValue))
                ON CONFLICT (path) DO NOTHING
                """).run()
        } catch {
            logger.warning("media scan row for \(path) failed: \(error)"); return
        }
        guard scannable else { return }
        if let queue {
            try? await queue.dispatch(BackgroundJobs.MediaScanJob.self, .init(path: path), maxRetryCount: 1)
        } else {
            Task { await OllamaGate.$isBackground.withValue(true) { await scan(path, app: app, logger: logger) } }
        }
    }

    // MARK: scanning

    /// Asks OpenAI about the file, up to three tries, and stores the verdict. A
    /// file that keeps failing is 'unscanned', never quietly 'clean'.
    static func scan(_ path: String, app: Application, logger: Logger) async {
        let cfg = app.appEnv.moderation
        let db = app.db.sql()
        let file = UploadsController.uploadDir + path.dropFirst("/uploads".count)
        // The phone's feed-size copy is smaller to send and always a JPEG.
        let thumb = file.replacingOccurrences(of: #"\.[A-Za-z0-9]+$"#, with: "_t.jpg", options: .regularExpression)
        let (readPath, readMime) = FileManager.default.fileExists(atPath: thumb) ? (thumb, "image/jpeg") : (file, mime(forPath: path) ?? "image/jpeg")
        guard let data = FileManager.default.contents(atPath: readPath), data.count <= 20 * 1024 * 1024 else {
            await store(path, .unscanned, nil, [:], on: db, logger: logger); return
        }
        var result: OpenAIModeration.Result?
        for attempt in 1...3 {
            do {
                result = try await OpenAIModeration.checkImage(data, mime: readMime, key: cfg.openAIKey, model: cfg.openAIModel,
                                                               client: app.http.client.shared)
                break
            } catch {
                logger.warning("photo scan of \(path) failed (try \(attempt)): \(error)")
                if attempt < 3 { try? await Task.sleep(for: .seconds(Double(attempt) * 3)) }
            }
        }
        guard let result else {
            await store(path, .unscanned, nil, [:], on: db, logger: logger)
            return
        }
        let verdict = decide(result)
        await store(path, verdict.status, verdict.policy, result.scores, on: db, logger: logger)
        await reconcile(path: path, app: app, logger: logger)
    }

    private static func store(_ path: String, _ status: Status, _ policy: ModerationPolicy?, _ scores: [String: Double],
                              on db: any SQLDatabase, logger: Logger) async {
        let json = String(decoding: (try? JSONEncoder().encode(scores)) ?? Data("{}".utf8), as: UTF8.self)
        do {
            try await db.raw("""
                UPDATE media_scans SET status = \(bind: status.rawValue), policy = \(bind: policy?.rawValue),
                  scores = \(bind: json)::jsonb, provider = \(bind: status == .unscanned ? nil : "openai"), scanned_at = NOW()
                WHERE path = \(bind: path)
                """).run()
        } catch { logger.warning("storing photo verdict for \(path) failed: \(error)") }
    }

    // MARK: what a verdict does to content

    struct Flagged: Decodable { let path: String; let policy: String? }

    /// The scan verdict for each of `paths` that has been scanned and flagged.
    static func flagged(among paths: [String], on db: any SQLDatabase) async throws -> [Flagged] {
        guard !paths.isEmpty else { return [] }
        return try await db.raw("""
            SELECT path, policy FROM media_scans WHERE status = 'flagged' AND path = ANY(\(bind: paths)::text[])
            """).all(decoding: Flagged.self)
    }

    /// Everything that uses `path`: judged again after a scan lands, and again
    /// when new content is published. Idempotent — a case merges into the open one.
    static func reconcile(path: String, app: Application, logger: Logger) async {
        let db = app.db.sql()
        do {
            struct Row: Decodable { let status: String; let policy: String? }
            guard let row = try await db.raw("SELECT status, policy FROM media_scans WHERE path = \(bind: path)")
                .first(decoding: Row.self) else { return }
            guard row.status == "flagged", let policy = row.policy.flatMap(ModerationPolicy.init(rawValue:)) else { return }
            for ref in try await references(of: path, on: db) {
                try await flag(ref, policy: policy, path: path, app: app, logger: logger)
            }
        } catch {
            logger.warning("photo reconcile of \(path) failed: \(error)")
        }
    }

    struct Reference: Decodable {
        let kind: String        // post, comment, story, user, community, company
        let id: String
        let mode: String?
        let live: Bool
    }

    static func references(of path: String, on db: any SQLDatabase) async throws -> [Reference] {
        try await db.raw("""
            SELECT 'post' AS kind, id::text AS id, mode, (status = 'posted') AS live FROM posts
              WHERE image_urls @> ARRAY[\(bind: path)]::text[] AND status IN ('posted', 'pending')
            UNION ALL SELECT 'comment', c.id::text, p.mode, (c.status = 'posted') FROM comments c JOIN posts p ON p.id = c.post_id
              WHERE c.image_url = \(bind: path) AND c.status = 'posted'
            UNION ALL SELECT 'story', id::text, mode, (expires_at > NOW()) FROM stories WHERE image_url = \(bind: path)
            UNION ALL SELECT 'user', id::text, 'hobby', TRUE FROM users WHERE hobby_avatar_url = \(bind: path) OR hobby_cover_url = \(bind: path)
            UNION ALL SELECT 'user', id::text, 'work', TRUE FROM users WHERE work_avatar_url = \(bind: path) OR work_cover_url = \(bind: path)
            UNION ALL SELECT 'community', id::text, NULL, TRUE FROM communities WHERE avatar_url = \(bind: path) OR cover_url = \(bind: path)
            UNION ALL SELECT 'company', id::text, 'work', TRUE FROM companies WHERE logo_url = \(bind: path) OR cover_url = \(bind: path)
            """).all(decoding: Reference.self)
    }

    private static func flag(_ ref: Reference, policy: ModerationPolicy, path: String, app: Application, logger: Logger) async throws {
        let db = app.db.sql()
        // Reference kinds are ReportTarget raw values.
        guard let type = ReportTarget(rawValue: ref.kind),
              let target = try await ModerationStore.target(type, ref.id, mode: ref.mode, reporter: "", on: db) else { return }
        let cfg = app.appEnv.moderation
        let verdict: [String: Any] = ["source": "image", "policy": policy.rawValue, "path": path, "shadow": !cfg.enforcing]
        let filed = try await ModerationStore.openAutoCase(type: type, id: ref.id, target: target, policy: policy,
                                                           verdict: verdict, on: db)
        if filed.opened {
            try await ModerationStore.log(caseID: filed.case_id, actor: nil, action: "auto_flagged",
                                          detail: ["policy": policy.rawValue, "source": "image", "mode": cfg.enforcing ? "enforce" : "shadow"], on: db)
            logger.info("moderation: photo \(path) flagged \(policy.rawValue) on \(ref.kind) \(ref.id)")
        }
        guard cfg.enforcing, policy.severity <= 1, ref.live,
              let c = try await ModerationService.loadCase(filed.case_id, on: db), c.status == "open", !c.auto_hidden else { return }
        try await app.db.tx { t in
            switch ref.kind {
            case "post", "comment", "story":
                try await ModerationService.takeDown(c, on: t)
            case "user":
                // Only the flagged picture goes, not the whole profile.
                let p = ref.mode == "work" ? "work" : "hobby"
                try await t.raw("""
                    UPDATE users SET
                      \(unsafeRaw: p)_avatar_url = CASE WHEN \(unsafeRaw: p)_avatar_url = \(bind: path) THEN NULL ELSE \(unsafeRaw: p)_avatar_url END,
                      \(unsafeRaw: p)_cover_url  = CASE WHEN \(unsafeRaw: p)_cover_url  = \(bind: path) THEN NULL ELSE \(unsafeRaw: p)_cover_url END
                    WHERE id = \(uuid: ref.id)
                    """).run()
            default:
                return   // communities and company pages: a person decides, nothing is hidden meanwhile
            }
            try await t.raw("UPDATE moderation_cases SET auto_hidden = TRUE, updated_at = NOW() WHERE id = \(uuid: c.id)").run()
            try await ModerationStore.log(caseID: c.id, actor: nil, action: "auto_hidden", on: t)
        }
        if let author = target.author_id, ["post", "comment", "story", "user"].contains(ref.kind) {
            await ModerationNotices.held(caseID: c.id, authorID: author, target: type, on: db, hub: app.socketHub, logger: logger)
        }
    }

    // MARK: removed photos can't come back

    /// Photos in a removed case whose reason is nudity, child safety or
    /// violence are banned by their hash, so the same file can't be uploaded again.
    static func banPhotos(in snapshot: String, policy: ModerationPolicy, on db: any SQLDatabase) async {
        guard [.nuditySexual, .childSafety, .violence].contains(policy) else { return }
        let paths = uploadPaths(in: snapshot)
        guard !paths.isEmpty else { return }
        try? await db.raw("""
            INSERT INTO banned_media (sha256, policy)
            SELECT DISTINCT sha256, \(bind: policy.rawValue) FROM media_scans WHERE path = ANY(\(bind: paths)::text[])
            ON CONFLICT (sha256) DO NOTHING
            """).run()
    }

    static func uploadPaths(in snapshot: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #""(/uploads/[A-Za-z0-9_.\-]+)""#)
        let range = NSRange(snapshot.startIndex..., in: snapshot)
        return re.matches(in: snapshot, range: range).compactMap {
            Range($0.range(at: 1), in: snapshot).map { String(snapshot[$0]) }
        }
    }
}

extension BackgroundJobs {
    struct MediaScanJob: AsyncJob {
        struct Payload: Codable, Sendable { let path: String }
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            await MediaScan.scan(payload.path, app: context.application, logger: context.logger)
        }
    }
}
