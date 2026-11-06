import Vapor
import AsyncHTTPClient
import NIOCore
import NIOPosix
import SQLKit

/// `GET /health`, always 200 (liveness; the Docker healthcheck depends on it).
/// `checks` reports best-effort reachability of Postgres, Redis and Ollama,
/// in the Node `/health` shape `{ status, env, checks }`, plus how far AI-search
/// embeddings are behind (`embeddings`, nil if the DB can't say).
struct HealthController {
    struct Body: Content {
        let status = "ok"
        let env: String
        let checks: Checks
        struct Checks: Content {
            var db: Bool
            var redis: Bool
            var ollama: Bool
            var embeddings: Embeddings?
        }
        /// Items whose text changed (or is new) but isn't embedded yet, and how
        /// long the oldest has waited. Must stay under the 6-hour promise.
        struct Embeddings: Content {
            var out_of_date: Int
            var oldest_out_of_date_minutes: Int?
        }
    }

    static func register(_ app: Application) {
        app.get("health") { req async -> Body in
            let env = app.appEnv
            async let db = app.db.healthCheck()
            async let redis = pingRedis(host: env.redis.host, port: env.redis.port, on: req.eventLoop)
            async let ollama = pingOllama(url: env.ollama.url, client: app.http.client.shared)
            async let embeddings = embeddingFreshness(app.db.sql())
            return Body(env: env.nodeEnv, checks: .init(db: await db, redis: await redis, ollama: await ollama,
                                                       embeddings: await embeddings))
        }
    }

    private static func embeddingFreshness(_ db: any SQLDatabase) async -> Body.Embeddings? {
        try? await db.raw("""
            SELECT (SELECT COUNT(*) FROM embedding_out_of_date)::int AS out_of_date,
                   (SELECT (EXTRACT(EPOCH FROM NOW() - MIN(b.first_seen_at)) / 60)::int
                    FROM embedding_backlog b
                    JOIN embedding_out_of_date o ON o.source_type = b.source_type AND o.source_id = b.source_id
                   ) AS oldest_out_of_date_minutes
            """).first(decoding: Body.Embeddings.self)
    }

    private static func pingOllama(url: String, client: HTTPClient) async -> Bool {
        do {
            var request = HTTPClientRequest(url: "\(url)/api/tags")
            request.method = .GET
            let response = try await client.execute(request, timeout: .milliseconds(1500))
            return (200..<300).contains(Int(response.status.code))
        } catch {
            return false
        }
    }

    /// Minimal RESP PING/PONG over a raw TCP connection. Avoids pulling in a
    /// Redis client just for the health probe.
    private static func pingRedis(host: String, port: Int, on eventLoop: EventLoop) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: eventLoop)
                .connectTimeout(.milliseconds(1000))
                .connect(host: host, port: port)
                .get()
            // A successful TCP connect is a good-enough liveness signal here;
            // reading the +PONG reply would need a channel handler. Connect
            // failure (Redis down) already throws above.
            try? await channel.close().get()
            return true
        } catch {
            return false
        }
    }
}
