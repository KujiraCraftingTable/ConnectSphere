import Vapor
import SQLKit
import Crypto
import Queues

/// English ↔ Vietnamese translations of posts and comments (migration 048),
/// made on the server when content is published or edited so the app only
/// has to swap text. Any other language is recorded and left untranslated.
enum TranslationService {
    enum Kind: String, Codable, Sendable {
        case post, comment
        /// Allowlisted table names — never built from input.
        var table: String { self == .post ? "posts" : "comments" }
    }

    // MARK: language detection

    /// Letters that only Vietnamese uses among en/vi (plus the tone-marked
    /// vowels of Latin Extended Additional, U+1EA0–1EF9).
    private static let vietnameseLetters = Set("ăâđêôơưàáãèéìíòóõùúýĩũĂÂĐÊÔƠƯÀÁÃÈÉÌÍÒÓÕÙÚÝĨŨ".unicodeScalars)

    /// "vi", "en", "other", or nil when there's nothing to translate (emoji,
    /// links, a stray letter). Vietnamese written without accents reads as
    /// English here — a known limit of a heuristic this cheap.
    static func detectLanguage(_ raw: String) -> String? {
        let text = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"https?://\S+|[#@]\S+"#, with: " ", options: .regularExpression)
        var latin = 0, vietnamese = 0, other = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if vietnameseLetters.contains(scalar) || (0x1EA0...0x1EF9).contains(scalar.value) {
                vietnamese += 1; latin += 1
            } else if scalar.value < 0x0250 {
                latin += 1
            } else {
                other += 1
            }
        }
        guard latin + other >= 3 else { return nil }
        if other > latin { return "other" }
        // Real Vietnamese has accents on a good share of its letters; an
        // English sentence with one Vietnamese name doesn't.
        return Double(vietnamese) / Double(latin) >= 0.08 ? "vi" : "en"
    }

    /// The model's reply minus wrappers it sometimes adds ("Translation:",
    /// quotes around the whole thing).
    static func cleanOutput(_ raw: String, source: String) -> String {
        // A reasoning block, should a model think despite `think: false`.
        var out = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Qwen3 sometimes ends with a slash command of its own (`/no_think`,
        // `/no_translate`, …). Dropped unless the source ends with it too.
        if let range = out.range(of: #"\s*/[A-Za-z_]+$"#, options: .regularExpression) {
            let command = out[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(command) {
                out = String(out[..<range.lowerBound])
            }
        }
        for prefix in ["Translation:", "Bản dịch:", "Translated text:"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”")]
        for (open, close) in quotes where out.count > 1 && out.first == open && out.last == close
            && source.first != open {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    /// sha256 hex — must match the SQL `hashExpr` below byte for byte.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The same hash computed in SQL over a row's current content.
    static func hashExpr(_ alias: String) -> String {
        "encode(sha256(convert_to(coalesce(\(alias).content, ''), 'UTF8')), 'hex')"
    }

    /// The translation to send with a row: only while it still matches the
    /// content (an edit makes it stale until it's redone).
    static func translatedColumn(_ alias: String) -> String {
        "CASE WHEN \(alias).translated_hash = \(hashExpr(alias)) THEN \(alias).translated_text END"
    }

    // MARK: doing the work

    /// Translates one post or comment if it needs it. Safe to call twice: a
    /// row whose hash already matches is left alone, and the write only
    /// lands if the content hasn't changed meanwhile.
    static func translate(_ kind: Kind, id: String, app: Application, logger: Logger) async {
        guard let translator = Translators.make(app) else { return }
        let db = app.db.sql()
        struct Row: Decodable { let content: String?; let translated_hash: String?; let lang: String? }
        guard let row = try? await db.raw("""
            SELECT content, translated_hash, lang FROM \(unsafeRaw: kind.table)
            WHERE id = \(uuid: id) AND status = 'posted'
            """).first(decoding: Row.self) else { return }
        let text = row.content ?? ""
        let digest = hash(text)
        if row.lang != nil, row.translated_hash == digest { return }

        let lang = detectLanguage(text)
        var translated: String?
        if let lang, lang == "en" || lang == "vi" {
            do {
                translated = try await translator.translate(text, from: lang, to: lang == "en" ? "vi" : "en")
            } catch {
                logger.warning("Translation of \(kind.rawValue) \(id) failed: \(error)")
            }
            if translated?.isEmpty ?? true {
                // Note the language but not the hash: the sweep tries again
                // later, behind content it has never looked at.
                try? await db.raw("""
                    UPDATE \(unsafeRaw: kind.table) SET lang = \(bind: lang) WHERE id = \(uuid: id) AND lang IS NULL
                    """).run()
                return
            }
        }
        try? await db.raw("""
            UPDATE \(unsafeRaw: kind.table)
            SET lang = \(bind: lang ?? "none"), translated_text = \(bind: translated), translated_hash = \(bind: digest)
            WHERE id = \(uuid: id) AND \(unsafeRaw: hashExpr(kind.table)) = \(bind: digest)
            """).run()
    }

    /// Queue (or, without RUN_JOBS, just start) a translation.
    static func enqueue(_ kind: Kind, id: String, app: Application, queue: any Queue, logger: Logger) async {
        guard app.appEnv.translation.enabled else { return }
        if BackgroundJobs.enabled {
            try? await queue.dispatch(BackgroundJobs.TranslateContentJob.self, .init(kind: kind, id: id), maxRetryCount: 2)
        } else {
            Task { await translate(kind, id: id, app: app, logger: logger) }
        }
    }

    static func enqueue(_ req: Request, _ kind: Kind, id: String) async {
        await enqueue(kind, id: id, app: req.application, queue: req.queue, logger: req.logger)
    }

    /// Rows never looked at, or whose content changed since: the backfill,
    /// and anything missed while the model was down.
    static func pending(_ kind: Kind, limit: Int, excluding tried: [UUID] = [], on db: any SQLDatabase) async throws -> [String] {
        struct I: Decodable { let id: String }
        return try await db.raw("""
            SELECT id::text AS id FROM \(unsafeRaw: kind.table) t
            WHERE t.status = 'posted' AND t.id <> ALL(\(bind: tried))
              AND (t.lang IS NULL OR t.translated_hash IS DISTINCT FROM \(unsafeRaw: hashExpr("t")))
            ORDER BY (t.lang IS NULL) DESC, t.created_at DESC
            LIMIT \(bind: limit)
            """).all(decoding: I.self).map(\.id)
    }
}
