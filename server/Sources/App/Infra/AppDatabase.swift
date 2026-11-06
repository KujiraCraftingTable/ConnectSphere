import Vapor
import PostgresKit
import PostgresNIO
import SQLKit

/// Thin wrapper over a PostgresKit connection pool. Exposes raw SQL (`sql()` → `SQLDatabase`) plus a
/// `withTransaction` helper with the same all-or-nothing contract.
final class AppDatabase: @unchecked Sendable {
    let pool: EventLoopGroupConnectionPool<PostgresConnectionSource>
    private let logger: Logger

    init(env: AppEnv, eventLoopGroup: any EventLoopGroup, logger: Logger) {
        let config = SQLPostgresConfiguration(
            hostname: env.db.host,
            port: env.db.port,
            username: env.db.user,
            password: env.db.password,
            database: env.db.database,
            tls: .disable
        )
        // `DB_POOL_MAX` is a total; spread it across the event loops,
        // but never below 4 each: on a 10-core Mac 10 / 10 left every loop one
        // connection, so one slow query (or a job) stalled every request on it.
        var loops = 0
        for _ in eventLoopGroup.makeIterator() { loops += 1 }
        let perLoop = max(4, env.db.poolMax / max(1, loops))
        self.pool = EventLoopGroupConnectionPool(
            source: PostgresConnectionSource(sqlConfiguration: config),
            maxConnectionsPerEventLoop: perLoop,
            // How long a request waits for a free connection; 2 s is too
            // tight while the job workers are busy.
            requestTimeout: .milliseconds(Int64(max(env.db.connectionTimeoutMS, 5000))),
            pruneInterval: .seconds(30),
            maxIdleTimeBeforePruning: .milliseconds(Int64(env.db.idleTimeoutMS)),
            on: eventLoopGroup
        )
        self.logger = logger
    }

    /// SQLKit query interface. Use `db.sql().raw("… \(bind: x) …")` for the
    /// ported queries (the `\(bind:)` interpolation emits `$1, $2, …` in order).
    func sql() -> any SQLDatabase {
        pool.database(logger: logger).sql()
    }

    /// Run `work` inside a single BEGIN/COMMIT on one pooled connection. Any
    /// thrown error triggers ROLLBACK and re-throws.
    func withTransaction<T: Sendable>(
        _ work: @Sendable @escaping (any SQLDatabase) async throws -> T
    ) async throws -> T {
        try await withConnection { conn in
            let db = conn.sql()
            try await db.raw("BEGIN").run()
            do {
                let result = try await work(db)
                try await db.raw("COMMIT").run()
                return result
            } catch {
                _ = try? await db.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    /// Borrow one pooled `PostgresConnection` for the duration of `work`.
    func withConnection<T: Sendable>(
        _ work: @Sendable @escaping (PostgresConnection) async throws -> T
    ) async throws -> T {
        try await pool.withConnection(logger: logger) { conn -> EventLoopFuture<T> in
            conn.eventLoop.makeFutureWithTask { try await work(conn) }
        }.get()
    }

    func healthCheck() async -> Bool {
        do {
            try await sql().raw("SELECT 1").run()
            return true
        } catch {
            return false
        }
    }

    func shutdown() {
        pool.shutdown()
    }
}

extension Application {
    private struct AppDatabaseKey: StorageKey { typealias Value = AppDatabase }
    var db: AppDatabase {
        get {
            guard let d = storage[AppDatabaseKey.self] else { fatalError("AppDatabase not configured") }
            return d
        }
        set { storage[AppDatabaseKey.self] = newValue }
    }

    /// Register on `app.lifecycle` so the pool is drained on shutdown (otherwise
    /// AsyncKit asserts in debug).
    struct DatabaseLifecycle: LifecycleHandler {
        func shutdown(_ application: Application) {
            application.db.shutdown()
        }
    }
}

extension Request {
    var db: AppDatabase { application.db }
}
