import Vapor
import SQLKit

/// Port of `backend/src/services/postTagExtractService.js` — LLM topic/entity
/// extraction → entity-registry expansion (Tier-1 exact + Tier-2 confident
/// vector; the Wikipedia self-learn tier is Phase 8) → dedup → bulk insert into
/// `post_tags` with `source = 'ai'`.
enum PostTagExtractService {
    static let systemPrompt = """
        You extract topics and entities from a social media post to use as searchable tags.
        Return ONLY a JSON array of strings. No explanation outside the array.
        All values must be in English.

        ── WHAT TO EXTRACT ──────────────────────────────────────────────────
        Extract TWO layers:
        1. Specific entities   — exact titles, character names, artist/band names, brand names, franchise names, company names, game titles, series names
        2. Category tags       — genre (anime, fantasy, action), activity (coffee, travel, coding), domain (fitness, music, cooking)

        ── WHAT NOT TO EXTRACT ──────────────────────────────────────────────
        NEVER extract:
        - Emotions, moods or feelings: "happy", "sad", "excited", "positive mood", "good vibes", "chill", "relax"
        - Adjectives describing quality: "amazing", "great", "awesome", "beautiful", "interesting", "funny"
        - Relationship/social words: "friend", "bạn", "người yêu", "couple", "together"
        - Filler/reaction words: "wow", "omg", "vãi", "lol", "haha"
        - Vague lifestyle words unless specific: "life", "daily", "routine", "moment", "thing"
        - Non-Latin characters (Japanese, Chinese, Korean): ウィストリア, 呪術廻戦

        ── VIETNAMESE → ENGLISH MAPPING (always translate) ──────────────────
        "xem anime/manga"    → ["anime", "manga"]
        "xem phim"          → ["movies", "film"]
        "nghe nhạc"         → ["music"]
        "đi cafe / cà phê"  → ["coffee", "cafe"]
        "chơi game"         → ["gaming"]
        "nấu ăn / ẩm thực"  → ["cooking", "food"]
        "đi du lịch"        → ["travel"]
        "gym / chạy bộ"     → ["fitness", "gym"]
        "lập trình / code"  → ["programming", "coding"]
        "sprint / deadline" → ["software development", "agile"]

        ── EXAMPLES ─────────────────────────────────────────────────────────
        "Ôi mình thích bộ wistoria vãi, Gallus đánh hay lắm!"
        → ["Wistoria", "Wistoria: Wand and Sword", "Gallus", "anime", "fantasy anime", "magic anime", "action anime"]

        "Tập mới của Jujutsu Kaisen ra rồi nè"
        → ["Jujutsu Kaisen", "JJK", "anime", "action anime", "shounen"]

        "Hôm nay đi cafe với bạn, uống trà sữa ngon ghê"
        → ["coffee", "cafe", "milk tea", "food and drink"]

        "Vừa xong sprint, team làm việc hiệu quả lắm"
        → ["software development", "agile", "sprint", "teamwork", "programming"]

        "Đi Đà Lạt với gia đình, cảnh đẹp quá"
        → ["travel", "Da Lat", "Vietnam", "nature"]

        "Nghe Taylor Swift cả ngày không chán"
        → ["Taylor Swift", "music", "pop music"]
        """

    static func extractRawTags(_ cfg: OllamaService.Config, _ content: String, logger: Logger) async -> [String] {
        (try? await OllamaService.rawChatArray(cfg, system: systemPrompt, user: content, temperature: 0.2)) ?? []
    }

    /// Expand each raw tag via exact + confident-vector tiers; add canonical
    /// name + aliases. (Wikipedia genre tags land in Phase 8.)
    static func expandTags(_ cfg: OllamaService.Config, _ rawTags: [String], on db: any SQLDatabase, logger: Logger) async -> [String] {
        var all = Set(rawTags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        struct NameAliases: Decodable { let canonical_name: String; let aliases: [String]? }
        for tag in rawTags {
            var entityID: String? = nil
            if let hit = try? await SearchStore.exactMatch(tag, category: nil, on: db) {
                entityID = hit.id
            } else if let vec = await OllamaService.embedText(cfg, tag, logger: logger),
                      let top = (try? await SearchStore.findEntityCandidates(vec, category: nil, limit: 1, on: db))?.first,
                      top.similarity >= SearchStore.highConfidenceThreshold {
                entityID = top.entity_id
            }
            guard let eid = entityID,
                  let row = try? await db.raw("SELECT canonical_name, aliases FROM interest_entities WHERE id = \(uuid: eid)")
                    .first(decoding: NameAliases.self) else { continue }
            all.insert(row.canonical_name.lowercased().trimmingCharacters(in: .whitespaces))
            for a in row.aliases ?? [] { all.insert(a.lowercased().trimmingCharacters(in: .whitespaces)) }
        }
        return all.filter { !$0.isEmpty }
    }

    static func savePostTags(_ postID: String, _ tags: [String], on db: any SQLDatabase) async throws {
        guard !tags.isEmpty else { return }
        try await db.raw("""
            INSERT INTO post_tags (post_id, tag, source)
            SELECT \(uuid: postID), UNNEST(\(bind: tags)::text[]), 'ai'
            ON CONFLICT (post_id, tag) DO NOTHING
            """).run()
    }

    static func extractAndSave(_ cfg: OllamaService.Config, postID: String, content: String, on db: any SQLDatabase, logger: Logger) async throws {
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let raw = await extractRawTags(cfg, content, logger: logger)
        guard !raw.isEmpty else { return }
        let tags = await expandTags(cfg, raw, on: db, logger: logger)
        try await savePostTags(postID, tags, on: db)
        logger.info("postTagExtract: \(tags.count) tags saved for \(postID)")
    }
}
