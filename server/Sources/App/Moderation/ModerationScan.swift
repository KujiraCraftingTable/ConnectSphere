import Vapor
import SQLKit
import Queues

/// The automatic check that runs after something is published (the word rules
/// have already run before): a rules look for scams, then the local safety
/// model, then — only when the model is unsure — OpenAI's free moderation for a
/// second opinion. A finding opens a case for the review queue; in `enforce`
/// mode, content the checks are sure is severe is also hidden until a person
/// decides (Meta's approach since 2025: automation acts alone only on severe
/// harm, everything else waits for a human).
enum ModerationScan {
    enum Kind: String, Codable, Sendable { case post, comment, profile, community, company }

    struct Payload: Codable, Sendable {
        let kind: Kind
        let id: String
        /// hobby / work, for a profile.
        let mode: String?
    }

    struct Finding: Equatable, Sendable {
        let policy: ModerationPolicy
        /// Whether `enforce` mode hides the content while it's reviewed.
        let hide: Bool
        let source: String
    }

    // MARK: deciding

    /// The most severe policy among the model's categories, if any matter here.
    static func worst(_ policies: [ModerationPolicy]) -> ModerationPolicy? {
        policies.min { $0.severity < $1.severity }
    }

    /// What the model's verdict, and OpenAI's second opinion on an unsure one,
    /// add up to. `Unsafe` about severe harm hides; `Controversial` never does
    /// on the model's word alone, and a second opinion that finds nothing ends it.
    static func decide(guardVerdict: LocalGuard.Verdict, openAI: OpenAIModeration.Result?) -> Finding? {
        let local = worst(guardVerdict.categories.compactMap(LocalGuard.policy(for:)))
        switch guardVerdict.level {
        case .safe:
            return nil
        case .unsafe:
            guard let local else { return nil }
            return Finding(policy: local, hide: local.severity <= 1, source: "guard")
        case .controversial:
            guard let openAI else {
                guard let local else { return nil }
                return Finding(policy: local, hide: false, source: "guard")
            }
            guard openAI.flagged, let policy = worst(openAI.categories.compactMap(OpenAIModeration.policy(for:))) ?? local else {
                return nil
            }
            return Finding(policy: policy, hide: policy.severity <= 1, source: "guard+openai")
        }
    }

    /// Scam-shaped text from a brand-new account is held; from anyone else it
    /// only goes to the queue.
    static func scamFinding(text: String, isNewAccount: Bool) -> Finding? {
        ModerationRules.looksLikeScam(text) ? Finding(policy: .scam, hide: isNewAccount, source: "rules") : nil
    }

    static func moreSevere(_ a: Finding?, _ b: Finding?) -> Finding? {
        switch (a, b) {
        case (nil, _): return b
        case (_, nil): return a
        case (let x?, let y?): return y.policy.severity < x.policy.severity ? y : x
        }
    }

    // MARK: the item

    struct Subject {
        let authorID: String
        let target: ReportTarget
        let mode: String?
        let text: String
        let isNewAccount: Bool
        /// Only live posts and comments can be hidden.
        let canHide: Bool
    }

    static func load(_ p: Payload, on db: any SQLDatabase) async throws -> Subject? {
        struct Row: Decodable {
            let author_id: String; let mode: String?; let text: String?; let status: String?; let created_at: Date
        }
        let q: SQLQueryString
        let target: ReportTarget
        switch p.kind {
        case .post:
            target = .post
            q = """
                SELECT p.author_id::text AS author_id, p.mode, concat_ws(E'\\n', p.content, p.article_title) AS text,
                  p.status::text AS status, u.created_at
                FROM posts p JOIN users u ON u.id = p.author_id WHERE p.id = \(uuid: p.id)
                """
        case .comment:
            target = .comment
            q = """
                SELECT c.author_id::text AS author_id, po.mode, c.content AS text, c.status::text AS status, u.created_at
                FROM comments c JOIN posts po ON po.id = c.post_id JOIN users u ON u.id = c.author_id
                WHERE c.id = \(uuid: p.id)
                """
        case .profile:
            target = .user
            let mode = p.mode == "work" ? "work" : "hobby"
            q = """
                SELECT u.id::text AS author_id, '\(unsafeRaw: mode)' AS mode,
                  concat_ws(E'\\n', u.\(unsafeRaw: mode)_display_name, u.\(unsafeRaw: mode)_bio) AS text, NULL AS status, u.created_at
                FROM users u WHERE u.id = \(uuid: p.id) AND u.deleted_at IS NULL
                """
        case .community:
            target = .community
            q = """
                SELECT c.created_by::text AS author_id, NULL AS mode, concat_ws(E'\\n', c.name, c.description) AS text,
                  NULL AS status, u.created_at
                FROM communities c JOIN users u ON u.id = c.created_by WHERE c.id = \(uuid: p.id)
                """
        case .company:
            target = .company
            q = """
                SELECT c.created_by::text AS author_id, 'work' AS mode, concat_ws(E'\\n', c.name, c.about) AS text,
                  NULL AS status, u.created_at
                FROM companies c JOIN users u ON u.id = c.created_by WHERE c.id = \(uuid: p.id)
                """
        }
        guard let r = try await db.raw(q).first(decoding: Row.self),
              let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return Subject(authorID: r.author_id, target: target, mode: r.mode, text: text,
                       isNewAccount: UserRateLimiter.isNewAccount(createdAt: r.created_at),
                       canHide: (p.kind == .post || p.kind == .comment) && r.status == "posted")
    }

    // MARK: running

    /// The uploaded photos this item shows.
    static func mediaPaths(_ p: Payload, on db: any SQLDatabase) async throws -> [String] {
        struct P: Decodable { let path: String? }
        let q: SQLQueryString
        switch p.kind {
        case .post: q = "SELECT unnest(image_urls) AS path FROM posts WHERE id = \(uuid: p.id)"
        case .comment: q = "SELECT image_url AS path FROM comments WHERE id = \(uuid: p.id)"
        case .profile:
            let m = p.mode == "work" ? "work" : "hobby"
            q = "SELECT \(unsafeRaw: m)_avatar_url AS path FROM users WHERE id = \(uuid: p.id) UNION ALL SELECT \(unsafeRaw: m)_cover_url FROM users WHERE id = \(uuid: p.id)"
        case .community: q = "SELECT avatar_url AS path FROM communities WHERE id = \(uuid: p.id) UNION ALL SELECT cover_url FROM communities WHERE id = \(uuid: p.id)"
        case .company: q = "SELECT logo_url AS path FROM companies WHERE id = \(uuid: p.id) UNION ALL SELECT cover_url FROM companies WHERE id = \(uuid: p.id)"        }
        return try await db.raw(q).all(decoding: P.self).compactMap(\.path).filter { $0.hasPrefix("/uploads/") }
    }

    static func run(_ p: Payload, app: Application, logger: Logger) async throws {
        let db = app.db.sql()
        // Photos first: if one was already flagged before this content existed,
        // the content is held now (a scan that lands later holds it itself).
        for path in (try? await mediaPaths(p, on: db)) ?? [] {
            await MediaScan.reconcile(path: path, app: app, logger: logger)
        }
        guard let subject = try await load(p, on: db) else { return }
        let cfg = app.appEnv.moderation

        let verdict = try await LocalGuard.classify(subject.text, model: cfg.guardModel, ollama: app.ollama)
        var openAI: OpenAIModeration.Result?
        if verdict.level == .controversial, !cfg.openAIKey.isEmpty {
            // A failed second opinion isn't fatal: the model's own word stands.
            openAI = try? await OpenAIModeration.check(text: subject.text, key: cfg.openAIKey, model: cfg.openAIModel,
                                                       client: app.http.client.shared)
        }
        let finding = moreSevere(decide(guardVerdict: verdict, openAI: openAI),
                                 scamFinding(text: subject.text, isNewAccount: subject.isNewAccount))
        guard let finding else { return }

        var verdicts: [String: Any] = ["source": finding.source, "policy": finding.policy.rawValue,
                                       "level": verdict.level.rawValue, "categories": verdict.categories,
                                       "shadow": !cfg.enforcing]
        if let openAI { verdicts["openai"] = ["flagged": openAI.flagged, "categories": openAI.categories] }

        guard let target = try await ModerationStore.target(subject.target, p.id, mode: subject.mode,
                                                            reporter: subject.authorID, on: db) else { return }
        let opened = try await ModerationStore.openAutoCase(type: subject.target, id: p.id, target: target,
                                                            policy: finding.policy, verdict: verdicts, on: db)
        try await ModerationStore.log(caseID: opened.case_id, actor: nil, action: "auto_flagged",
                                      detail: ["policy": finding.policy.rawValue, "source": finding.source,
                                               "mode": cfg.enforcing ? "enforce" : "shadow"], on: db)
        logger.info("moderation: \(p.kind.rawValue) \(p.id) flagged \(finding.policy.rawValue) (\(finding.source), \(cfg.enforcing ? "enforce" : "shadow"))")

        guard cfg.enforcing, finding.hide, subject.canHide,
              let c = try await ModerationService.loadCase(opened.case_id, on: db), c.status == "open", !c.auto_hidden else { return }
        try await app.db.tx { t in
            try await ModerationService.takeDown(c, on: t)
            try await t.raw("UPDATE moderation_cases SET auto_hidden = TRUE, updated_at = NOW() WHERE id = \(uuid: c.id)").run()
            try await ModerationStore.log(caseID: c.id, actor: nil, action: "auto_hidden", on: t)
        }
        await ModerationNotices.held(caseID: c.id, authorID: subject.authorID, target: subject.target,
                                     on: db, hub: app.socketHub, logger: logger)
    }

    // MARK: queueing

    /// Checks `id` after it's published or edited. With the job queue on (it
    /// owns the schedule) it's a job with retries; otherwise it just runs.
    static func enqueue(_ req: Request, _ kind: Kind, id: String, mode: String? = nil) async {
        let payload = Payload(kind: kind, id: id, mode: mode)
        if BackgroundJobs.enabled {
            try? await req.queue.dispatch(BackgroundJobs.ModerationScanJob.self, payload, maxRetryCount: 3)
        } else {
            runDetached(payload, app: req.application, logger: req.logger)
        }
    }

    static func enqueue(_ app: Application, queue: (any Queue)?, logger: Logger, _ kind: Kind, id: String, mode: String? = nil) async {
        let payload = Payload(kind: kind, id: id, mode: mode)
        if let queue {
            try? await queue.dispatch(BackgroundJobs.ModerationScanJob.self, payload, maxRetryCount: 3)
        } else {
            runDetached(payload, app: app, logger: logger)
        }
    }

    private static func runDetached(_ p: Payload, app: Application, logger: Logger) {
        Task {
            await OllamaGate.$isBackground.withValue(true) {
                do { try await run(p, app: app, logger: logger) }
                catch { logger.warning("moderation scan failed (\(p.kind.rawValue) \(p.id)): \(error)") }
            }
        }
    }
}

extension BackgroundJobs {
    struct ModerationScanJob: AsyncJob {
        typealias Payload = ModerationScan.Payload
        func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
            try await OllamaGate.$isBackground.withValue(true) {
                try await ModerationScan.run(payload, app: context.application, logger: context.logger)
            }
        }
    }
}
