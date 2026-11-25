import Vapor
import SQLKit

/// 4 AI search
/// suggestions per mode, generated from the last 7 days of `search_logs` via
/// the LLM, cached in `suggestion_cache` with a 1-hour TTL. Falls back to the
/// static defaults on any miss / failure.
enum SuggestionService {
    // MARK: - Defaults and prompts
    static let cacheTTL: TimeInterval = 60 * 60

    static let defaults: [String: [String]] = SearchController.defaultSuggestions

    static let prompts: [String: String] = [
        "hobby": """
            Bạn đang phân tích xu hướng tìm bạn bè trên ConnectSphere trong 7 ngày qua.

            Các query tìm kiếm phổ biến nhất:
            {QUERIES}

            Tạo 4 câu gợi ý tìm kiếm tiếng Việt cho người muốn tìm BẠN BÈ để chơi, giải trí, hẹn hò.
            Mỗi câu phải ngắn gọn, tự nhiên, phản ánh xu hướng trên.
            Trả về JSON thuần túy: {"suggestions": ["...", "...", "...", "..."]}
            """,
        "work": """
            Bạn đang phân tích xu hướng tìm đồng nghiệp/cộng tác viên trên ConnectSphere trong 7 ngày qua.

            Các query tìm kiếm phổ biến nhất:
            {QUERIES}

            Tạo 4 câu gợi ý tìm kiếm tiếng Việt cho người muốn tìm ĐỒNG NGHIỆP, CỘT TÁC VIÊN hoặc SINH VIÊN để học tập/làm việc.
            Mỗi câu phải ngắn gọn, tự nhiên, phản ánh xu hướng trên.
            Trả về JSON thuần túy: {"suggestions": ["...", "...", "...", "..."]}
            """,
    ]

    // MARK: - Generation and cache
    static func getSuggestions(mode: String?, cfg: OllamaService.Config, on db: any SQLDatabase, logger: Logger) async -> [String] {
        guard let mode, mode == "hobby" || mode == "work" else {
            return Array((defaults["hobby"]! + defaults["work"]!).prefix(4))
        }
        // 1. cache
        struct C: Decodable { let suggestions: String; let computed_at: Date }
        if let c = try? await db.raw("SELECT suggestions::text AS suggestions, computed_at FROM suggestion_cache WHERE mode = \(bind: mode)")
            .first(decoding: C.self),
           Date().timeIntervalSince(c.computed_at) <= cacheTTL,
           let arr = try? JSONDecoder().decode([String].self, from: Data(c.suggestions.utf8)) {
            return arr
        }
        // 2. trending queries
        struct Q: Decodable { let query: String }
        let queries = (try? await db.raw("""
            SELECT query FROM search_logs
            WHERE mode = \(bind: mode) AND created_at > NOW() - INTERVAL '7 days'
            GROUP BY query ORDER BY COUNT(*) DESC LIMIT 20
            """).all(decoding: Q.self))?.map(\.query) ?? []

        if queries.count < 3 {
            await writeCache(mode, defaults[mode]!, on: db)
            return defaults[mode]!
        }
        // 3. LLM
        do {
            let list = queries.enumerated().map { "\($0.offset + 1). \"\($0.element)\"" }.joined(separator: "\n")
            let prompt = prompts[mode]!.replacingOccurrences(of: "{QUERIES}", with: list)
            let j = try await OllamaService.rawChatObject(cfg, system: prompt, user: "Generate now.", temperature: 0.4)
            let sug = (j["suggestions"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard !sug.isEmpty else { throw Abort(.internalServerError) }
            let trimmed = Array(sug.prefix(4))
            await writeCache(mode, trimmed, on: db)
            return trimmed
        } catch {
            logger.warning("suggestion LLM failed (\(mode)): \(error)")
            await writeCache(mode, defaults[mode]!, on: db)
            return defaults[mode]!
        }
    }

    private static func writeCache(_ mode: String, _ suggestions: [String], on db: any SQLDatabase) async {
        let json = String(data: (try? JSONEncoder().encode(suggestions)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        try? await db.raw("""
            INSERT INTO suggestion_cache (mode, suggestions, computed_at) VALUES (\(bind: mode), \(bind: json)::jsonb, NOW())
            ON CONFLICT (mode) DO UPDATE SET suggestions = EXCLUDED.suggestions, computed_at = NOW()
            """).run()
    }
}
