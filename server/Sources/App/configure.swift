import Vapor

/// Boot-time wiring: security headers → rate limit → body parse → static → health →
/// routes → error handler.
public func configure(_ app: Application) async throws {
    // 1. Environment.
    //    `.env` is loaded by Vapor's DotEnvFile from the working directory; we
    //    point the process at `../backend/.env` in entrypoint before this runs.
    let env = try AppEnv.load()
    app.appEnv = env
    SpamSignals.enforcing = env.moderation.enforcing
    app.http.server.configuration.port = env.port
    app.http.server.configuration.hostname = "0.0.0.0"
    // JSON lists (feed, search) shrink several times over; only applied when
    // the client sends Accept-Encoding, which URLSession always does.
    app.http.server.configuration.responseCompression = .enabled

    // JSON in/out with fractional-second ISO-8601 dates.
    JSONCoding.install()

    // 2. Body size; upload routes raise it later.
    app.routes.defaultMaxBodySize = "128kb"

    // 3. Database pool (PostgresKit, raw SQL. No Fluent).
    app.db = AppDatabase(env: env, eventLoopGroup: app.eventLoopGroup, logger: app.logger)
    app.lifecycle.use(Application.DatabaseLifecycle())

    // 4. Middleware. Vapor's own ErrorMiddleware is replaced by ours so every
    //    error has the same JSON shape.
    app.middleware = .init()
    // Outermost, so it sees the final status of every request, errors included.
    app.middleware.use(RequestTimingMiddleware())
    app.middleware.use(AppErrorMiddleware(isProduction: env.isProduction, logger: app.logger))
    app.middleware.use(SecurityHeadersMiddleware())
    app.middleware.use(RateLimitMiddleware.global())

    app.asyncCommands.use(StripUploadMetadataCommand(), as: "strip-upload-metadata")
    app.asyncCommands.use(VerifyCompanyCommand(), as: "verify-company")
    app.asyncCommands.use(CommunityReportsCommand(), as: "community-reports")
    app.asyncCommands.use(ModeratorCommand(), as: "moderator")
    app.asyncCommands.use(OfficialAccountCommand(), as: "official-account")
    app.asyncCommands.use(ModerationCommand(), as: "moderation")
    app.asyncCommands.use(ModerationEvalCommand(), as: "moderation-eval")
    app.asyncCommands.use(SeedDemoCommand(), as: "seed-demo")

    // 5. Routes.
    HealthController.register(app)
    try routes(app)
    // Public static serving for uploaded media (`GET /uploads/:filename`,
    // bare path, see UploadsController.registerPublic for why this is a
    // narrow single-segment route and not a blanket FileMiddleware).
    UploadsController.registerPublic(app)
    // `/uploads/messages/*` (private chat attachments, photo/video/voice
    // messages), its own auth-gated route, see registerMessageMedia.
    UploadsController.registerMessageMedia(app)

    // 6. Run pending migrations at boot.
    //    Controlled by RUN_MIGRATIONS=1 so a plain `swift run` against an
    //    already-migrated DB is a no-op unless asked.
    if Environment.get("RUN_MIGRATIONS") == "1" {
        let dir = Environment.get("MIGRATIONS_DIR") ?? app.directory.workingDirectory + "../backend/migrations"
        let result = try await MigrationRunner.run(db: app.db, migrationsDir: dir, logger: app.logger)
        app.logger.info("migrations: \(result.applied.count) applied, \(result.skipped.count) already present")
    }

    // 7. Background jobs (Vapor Queues). Gated behind RUN_JOBS=1 so only the
    //    server that owns the schedule runs them.
    if BackgroundJobs.enabled {
        try BackgroundJobs.register(app)
        app.logger.info("background jobs + scheduler started (RUN_JOBS=1)")
    }
}
