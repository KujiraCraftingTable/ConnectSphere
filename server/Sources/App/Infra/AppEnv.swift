import Vapor

/// Typed environment configuration, read from `backend/.env`.
struct AppEnv: Sendable {
    struct DB: Sendable {
        var host: String
        var port: Int
        var database: String
        var user: String
        var password: String
        var poolMax: Int
        var idleTimeoutMS: Int
        var connectionTimeoutMS: Int
    }
    struct JWT: Sendable {
        var secret: String
        var expiresIn: String
    }
    /// Brevo's HTTP API sends the email codes; without a key they're logged
    /// (development).
    struct Mail: Sendable {
        var brevoKey: String
        var from: String
        var fromName: String
    }
    struct Ollama: Sendable {
        var url: String
        var model: String
    }
    /// The translation pipeline's own model (see `Translators`): defaults to
    /// the general Ollama model until a translation-only one is chosen.
    struct Translation: Sendable {
        var url: String
        var model: String
        var timeoutSeconds: Int
        var enabled: Bool
    }
    struct Redis: Sendable {
        var host: String
        var port: Int
    }
    /// Automatic content checks (`Moderation/`). `shadow` records what the AI
    /// thinks and opens cases for people to judge, but hides nothing;
    /// `enforce` also hides what it's sure about until a moderator decides.
    struct Moderation: Sendable {
        var enforcing: Bool
        /// A Qwen3Guard build served by the same Ollama.
        var guardModel: String
        /// Empty = no second opinion; unsure items go to the review queue.
        var openAIKey: String
        var openAIModel: String
    }
    /// Routes under `/api/test` for the XCUITest suite (`TestHooksController`).
    /// Off unless `UITEST_HOOKS=1`; then a `UITEST_TOKEN` of at least 32
    /// characters is required and production refuses to boot.
    struct UITest: Sendable {
        var hooksEnabled: Bool
        var token: String
    }

    var port: Int
    var nodeEnv: String
    var isProduction: Bool
    var corsOrigins: [String]
    var googleClientId: String
    var jwt: JWT
    var mail: Mail
    var ollama: Ollama
    var translation: Translation
    var moderation: Moderation
    var redis: Redis
    var db: DB
    var uitest: UITest

    /// Placeholder secrets, production must never boot with one.
    static let weakJWTSecrets: Set<String> = [
        "dev_secret",
        "change-me-generate-with-openssl-rand-hex-32",
    ]

    enum ValidationError: Error, CustomStringConvertible {
        case missing([String])
        case weakJWTInProduction
        case uitestHooksInProduction
        case weakUITestToken
        var description: String {
            switch self {
            case .missing(let keys): return "Missing required environment variables: \(keys.joined(separator: ", "))"
            case .weakJWTInProduction: return "JWT_SECRET must be set to a strong, unique value in production"
            case .uitestHooksInProduction: return "UITEST_HOOKS must never be on in production"
            case .weakUITestToken: return "UITEST_HOOKS=1 needs a UITEST_TOKEN of at least 32 characters"
            }
        }
    }

    /// Reads and validates the process environment. `get` is injected so tests
    /// can supply a fixed dictionary.
    static func load(_ get: (String) -> String? = { Environment.get($0) }) throws -> AppEnv {
        let required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
        let missing = required.filter { (get($0) ?? "").isEmpty }
        if !missing.isEmpty { throw ValidationError.missing(missing) }

        let nodeEnv = get("NODE_ENV") ?? "development"
        let isProd = nodeEnv == "production"
        let jwtSecret = get("JWT_SECRET") ?? "dev_secret"
        let weakJWT = jwtSecret.isEmpty || weakJWTSecrets.contains(jwtSecret)
        if isProd && weakJWT { throw ValidationError.weakJWTInProduction }
        let uitestHooks = get("UITEST_HOOKS") == "1"
        let uitestToken = get("UITEST_TOKEN") ?? ""
        if uitestHooks && isProd { throw ValidationError.uitestHooksInProduction }
        if uitestHooks && uitestToken.count < 32 { throw ValidationError.weakUITestToken }

        func int(_ key: String, _ fallback: Int) -> Int { Int(get(key) ?? "") ?? fallback }

        return AppEnv(
            port: int("PORT", 3000),
            nodeEnv: nodeEnv,
            isProduction: isProd,
            corsOrigins: (get("CORS_ORIGINS") ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            googleClientId: get("GOOGLE_CLIENT_ID") ?? "",
            jwt: JWT(secret: jwtSecret, expiresIn: get("JWT_EXPIRES_IN") ?? "90d"),
            mail: Mail(
                brevoKey: get("BREVO_API_KEY") ?? "",
                from: get("MAIL_FROM") ?? "",
                fromName: get("MAIL_FROM_NAME") ?? "ConnectSphere"
            ),
            ollama: Ollama(
                url: get("OLLAMA_URL") ?? "http://localhost:11434",
                model: get("OLLAMA_MODEL") ?? "qwen2.5:7b-instruct-q4_k_m"
            ),
            translation: Translation(
                url: get("TRANSLATION_URL") ?? get("OLLAMA_URL") ?? "http://localhost:11434",
                model: get("TRANSLATION_MODEL") ?? get("OLLAMA_MODEL") ?? "qwen2.5:7b-instruct-q4_k_m",
                timeoutSeconds: int("TRANSLATION_TIMEOUT", 60),
                enabled: (get("TRANSLATION_ENABLED") ?? "1") != "0"
            ),
            moderation: Moderation(
                enforcing: get("MODERATION_MODE") == "enforce",
                guardModel: get("MODERATION_GUARD_MODEL") ?? "huggingface.co/mradermacher/Qwen3Guard-Gen-4B-GGUF:Q4_K_M",
                openAIKey: get("OPENAI_API_KEY") ?? "",
                openAIModel: get("OPENAI_MODERATION_MODEL") ?? "omni-moderation-latest"
            ),
            redis: Redis(
                host: get("REDIS_HOST") ?? "localhost",
                port: int("REDIS_PORT", 6379)
            ),
            db: DB(
                host: get("DB_HOST") ?? "localhost",
                port: int("DB_PORT", 5432),
                database: get("DB_NAME") ?? "connectsphere",
                user: get("DB_USER") ?? "connectsphere_user",
                password: get("DB_PASSWORD") ?? "",
                poolMax: int("DB_POOL_MAX", 10),
                idleTimeoutMS: int("DB_POOL_IDLE_TIMEOUT", 30000),
                connectionTimeoutMS: int("DB_POOL_CONNECTION_TIMEOUT", 2000)
            ),
            uitest: UITest(hooksEnabled: uitestHooks, token: uitestHooks ? uitestToken : "")
        )
    }
}

extension Application {
    private struct AppEnvKey: StorageKey { typealias Value = AppEnv }
    var appEnv: AppEnv {
        get {
            guard let e = storage[AppEnvKey.self] else { fatalError("AppEnv not configured") }
            return e
        }
        set { storage[AppEnvKey.self] = newValue }
    }
}
