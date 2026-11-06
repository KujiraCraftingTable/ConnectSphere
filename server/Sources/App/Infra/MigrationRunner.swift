import Vapor
import PostgresKit
import PostgresNIO
import SQLKit

/// Replays `backend/migrations/*.sql` in filename order, recording each file in the
/// `schema_migrations` table, one transaction per file. A session-level Postgres
/// advisory lock keeps two runners from applying the same file twice.
enum MigrationRunner {
    /// Arbitrary but stable advisory-lock key.
    static let lockKey: Int = 0x636F_6E73  // "cons"

    struct Result: Content {
        var applied: [String]
        var skipped: [String]
    }

    static func run(db: AppDatabase, migrationsDir: String, logger: Logger) async throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: migrationsDir) else {
            throw Abort(.internalServerError, reason: "migrations dir not found: \(migrationsDir)")
        }
        let files = try fm.contentsOfDirectory(atPath: migrationsDir)
            .filter { $0.hasSuffix(".sql") }
            .sorted()

        return try await db.withConnection { conn in
            let sdb = conn.sql()
            try await sdb.raw("SELECT pg_advisory_lock(\(bind: lockKey))").run()
            do {
                let result = try await Self.applyAll(sdb: sdb, dir: migrationsDir, files: files, logger: logger)
                try? await sdb.raw("SELECT pg_advisory_unlock(\(bind: lockKey))").run()
                return result
            } catch {
                try? await sdb.raw("SELECT pg_advisory_unlock(\(bind: lockKey))").run()
                throw error
            }
        }
    }

    private static func applyAll(
        sdb: any SQLDatabase, dir: String, files: [String], logger: Logger
    ) async throws -> Result {
        try await sdb.raw("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
              filename   VARCHAR(255) PRIMARY KEY,
              applied_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
            )
            """).run()

        let rows = try await sdb.raw("SELECT filename FROM schema_migrations").all()
        let applied = Set(rows.compactMap { try? $0.decode(column: "filename", as: String.self) })

        var didApply: [String] = []
        var didSkip: [String] = []
        for file in files {
            if applied.contains(file) { didSkip.append(file); continue }
            let sql = try String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
            let statements = SQLScript.statements(sql)
            logger.info("migrate: applying \(file) (\(statements.count) statements)")
            do {
                try await sdb.raw("BEGIN").run()
                for stmt in statements {
                    try await sdb.raw(SQLQueryString(stringLiteral: stmt)).run()
                }
                try await sdb.raw("INSERT INTO schema_migrations (filename) VALUES (\(bind: file))").run()
                try await sdb.raw("COMMIT").run()
                didApply.append(file)
            } catch {
                try? await sdb.raw("ROLLBACK").run()
                logger.error("migrate: \(file) failed: \(String(reflecting: error))")
                throw error
            }
        }
        return Result(applied: didApply, skipped: didSkip)
    }
}
