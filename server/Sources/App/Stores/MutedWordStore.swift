import Vapor
import SQLKit

/// Muted words (migration 042): per user and mode. Every query is scoped to
/// the owner. Matching against posts and comments lives in `PostStore`
/// (`notMutedWordsClause` / `mutedWordHit`).
enum MutedWordStore {
    static let modes: Set<String> = ["hobby", "work"]
    static let maxWordsPerMode = 200
    static let maxLength = 50

    /// Duration key → seconds; nil = forever. The app shows these as
    /// 24 hours / 7 days / 30 days / Forever.
    static let durations: [String: Int?] = [
        "24h": 86_400, "7d": 604_800, "30d": 2_592_000, "forever": nil,
    ]

    struct Word: Content {
        var id: String
        var word: String
        @NullCoded var expires_at: Date?
        var created_at: Date
    }

    /// The word to store, or nil when it can't match anything: trimmed, inner
    /// whitespace collapsed, a leading `#` dropped (tags are matched anyway),
    /// 1–50 characters, and at least one letter or digit. Matching ignores
    /// punctuation, so "!!!" would never hide a thing.
    static func cleanWord(_ raw: String?) -> String? {
        guard var word = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while word.hasPrefix("#") { word.removeFirst() }
        word = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !word.isEmpty, word.count <= maxLength,
              word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return word
    }

    private static let unexpired = "(expires_at IS NULL OR expires_at > NOW())"

    static func list(owner: String, mode: String, on db: any SQLDatabase) async throws -> [Word] {
        try await db.raw("""
            SELECT id::text AS id, word, expires_at, created_at FROM muted_words
            WHERE user_id = \(uuid: owner) AND mode = \(bind: mode) AND \(unsafeRaw: unexpired)
            ORDER BY created_at DESC
            """).all(decoding: Word.self)
    }

    static func count(owner: String, mode: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(*)::int AS n FROM muted_words
            WHERE user_id = \(uuid: owner) AND mode = \(bind: mode) AND \(unsafeRaw: unexpired)
            """).first(decoding: N.self)?.n ?? 0
    }

    /// Adding a word that's already there (any case) sets its new duration
    /// rather than failing, "mute this for 30 days instead" just works.
    static func add(owner: String, mode: String, word: String, seconds: Int?, on db: any SQLDatabase) async throws -> Word {
        let expires = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
        return try await db.raw("""
            INSERT INTO muted_words (user_id, mode, word, expires_at)
            VALUES (\(uuid: owner), \(bind: mode), \(bind: word), \(bind: expires))
            ON CONFLICT (user_id, mode, lower(word))
              DO UPDATE SET expires_at = EXCLUDED.expires_at, created_at = NOW()
            RETURNING id::text AS id, word, expires_at, created_at
            """).first(decoding: Word.self)!
    }

    static func delete(_ id: String, owner: String, on db: any SQLDatabase) async throws -> Bool {
        struct I: Decodable { let id: String }
        return try await db.raw("""
            DELETE FROM muted_words WHERE id = \(uuid: id) AND user_id = \(uuid: owner) RETURNING id::text AS id
            """).first(decoding: I.self) != nil
    }

    /// Copies the unexpired words of one mode into the other, keeping their
    /// expiry. Words the target already has are left as they are. Returns how
    /// many were added.
    static func copy(owner: String, from: String, to: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            WITH added AS (
              INSERT INTO muted_words (user_id, mode, word, expires_at)
              SELECT user_id, \(bind: to), word, expires_at FROM muted_words
              WHERE user_id = \(uuid: owner) AND mode = \(bind: from) AND \(unsafeRaw: unexpired)
              ON CONFLICT (user_id, mode, lower(word)) DO NOTHING
              RETURNING 1
            )
            SELECT COUNT(*)::int AS n FROM added
            """).first(decoding: N.self)?.n ?? 0
    }
}
