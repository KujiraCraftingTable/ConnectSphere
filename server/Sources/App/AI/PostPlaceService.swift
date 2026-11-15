import Vapor
import SQLKit

/// Reads the places written in a post as today's wards and keeps them on the
/// post (`posts.place_ward_ids`, migration 147), so post search can compare
/// the place a prompt names with the place a post is about, ward against ward.
///
/// The LLM says which words are places (`OllamaService.extractPlaces`): most
/// ward names are everyday words. `PlaceReader` then reads each phrase, with
/// the geocoder behind it for street addresses. A name found in several
/// provinces is read in the author's own.
enum PostPlaceService {
    /// Whether the post's places have been read (even if it names none).
    static func isRead(_ postID: String, on db: any SQLDatabase) async throws -> Bool {
        struct Row: Decodable { let read: Bool }
        return try await db.raw("SELECT place_ward_ids IS NOT NULL AS read FROM posts WHERE id = \(uuid: postID)")
            .first(decoding: Row.self)?.read ?? true
    }

    /// Reads and stores the post's places. A failed LLM call throws and leaves
    /// the post unread; the sweep comes back to it.
    static func tag(_ postID: String, cfg: OllamaService.Config, on db: any SQLDatabase, logger: Logger) async throws {
        struct Row: Decodable {
            let author_id: String; let content: String?; let content_format: String?; let article_title: String?
        }
        guard let post = try await db.raw("""
            SELECT author_id::text AS author_id, content, content_format, article_title FROM posts WHERE id = \(uuid: postID)
            """).first(decoding: Row.self) else { return }
        let words = post.content_format == "markdown" ? post.content.map(MarkdownText.plain) : post.content
        let text = [post.article_title, words].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")

        var places = PlaceReader.Places()
        // No name of ours and no number in the text: nothing to ask the LLM.
        let rough = PlaceReader.read(text, in: try await PlaceReader.gazetteer(on: db), bare: true)
        if !rough.isEmpty || rough.street {
            let phrases = try await OllamaService.extractPlaces(cfg, text)
            // A province the post names places its other phrases too ("Hồ
            // Tây … Hà Nội"); otherwise the author's own province does.
            let gazetteer = try await PlaceReader.gazetteer(on: db)
            let named = phrases.reduce(into: Set<String>()) {
                $0.formUnion(PlaceReader.read($1, in: gazetteer, bare: true).provinceCodes)
            }
            let authors = try await WardStore.provinceCode(named: nil, orOfUser: post.author_id, on: db)
            let home = named.count == 1 ? named.first : authors
            for phrase in phrases {
                let found = try await PlaceReader.resolve([phrase], homeProvince: home, strictHome: true,
                                                              venuesInHome: named.count == 1,
                                                              client: cfg.client, on: db, logger: logger)
                places.wardIDs.formUnion(found.wardIDs)
                places.provinceCodes.formUnion(found.provinceCodes)
            }
        }
        try await store(postID, places, on: db)
    }

    static func store(_ postID: String, _ places: PlaceReader.Places, on db: any SQLDatabase) async throws {
        let wards = Array(places.wardIDs), provinces = Array(places.provinceCodes)
        try await db.raw("""
            UPDATE posts SET
              place_ward_ids = \(bind: wards)::uuid[],
              place_province_codes = ARRAY(
                SELECT province_code FROM vn_wards WHERE id = ANY(\(bind: wards)::uuid[])
                UNION SELECT unnest(\(bind: provinces)::text[]))
            WHERE id = \(uuid: postID)
            """).run()
    }
}
