import Vapor
import AsyncHTTPClient

/// Tier-3 entity lookup:
/// Wikipedia REST summary + MediaWiki langlinks/categories, then an LLM parse
/// into `{ canonical_name, category, aliases, genre_tags }`. Best-effort, any
/// failure returns nil and the caller falls back to embedding the raw text.
enum WikipediaService {
    static let genericTags: Set<String> = [
        "anime", "manga", "manhwa", "manhua", "movies", "film", "music", "gaming", "game",
        "travel", "food", "coffee", "cafe", "fitness", "gym", "coding", "programming",
        "cooking", "nature", "lifestyle", "sports", "fashion", "tech", "science", "art",
        "photography", "reading", "books", "shopping", "beauty", "health",
        "fantasy", "action", "romance", "comedy", "horror", "thriller", "drama", "sci-fi",
        "fantasy anime", "action anime", "shounen", "shonen", "seinen", "josei", "isekai",
        "pop music", "rock music", "hip hop", "jazz", "classical music", "k-pop",
        "food and drink", "milk tea", "bubble tea",
        "software development", "agile", "sprint", "teamwork",
        "vietnam", "hanoi", "ho chi minh city", "da lat",
    ]

    static func isProperNoun(_ tag: String) -> Bool {
        if genericTags.contains(tag.lowercased()) { return false }
        return tag.rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    static let parsePrompt = """
        Given Wikipedia data about an entity, extract structured information.
        Return ONLY a JSON object. No explanation outside the JSON.

        {
          "canonical_name": "official English Wikipedia page title",
          "category": "one of: Anime, Manga, Game, Movie, TVShow, Music, Artist, Book, Sport, Brand, Person, Place, Other",
          "aliases": ["all name variants, EN title, JA title, VI title, abbreviations, alternate spellings"],
          "genre_tags": ["lowercase genre/type search tags, e.g. anime, fantasy, action, NOT the entity name itself"]
        }

        Rules:
        - canonical_name: use the exact Wikipedia EN page title
        - aliases: include every language title provided + common short forms / abbreviations
        - genre_tags: generic searchable terms only, all lowercase, no entity name, no CJK characters
        - No duplicate values in any array
        """

    struct WikiData { var title: String; var description: String; var extract: String; var titles: [String: String]; var categories: [String] }
    struct Parsed { var canonicalName: String; var category: String; var aliases: [String]; var genreTags: [String] }

    private static let ua = "ConnectSphere/1.0 (education project)"

    struct Summary: Decodable { let type: String?; let title: String; let description: String?; let extract: String? }

    /// The page summary for an exact title; nil when there's no such page.
    private static func summary(_ title: String, client: HTTPClient) async throws -> Summary? {
        let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        var req = HTTPClientRequest(url: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        req.headers.add(name: "user-agent", value: ua)
        let res = try await client.execute(req, timeout: .seconds(8))
        guard (200..<300).contains(Int(res.status.code)) else { return nil }
        return try JSONDecoder().decode(Summary.self, from: try await res.body.collect(upTo: 512 * 1024))
    }

    /// Titles are case-sensitive after the first letter ("Kimishinu" 404s,
    /// "KimiShinu" redirects to the anime), so a miss asks Wikipedia's
    /// case-insensitive title search for the page instead.
    private static func searchTitle(_ term: String, client: HTTPClient) async throws -> String? {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        var req = HTTPClientRequest(url: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(q)&limit=1&namespace=0&format=json")
        req.headers.add(name: "user-agent", value: ua)
        let res = try await client.execute(req, timeout: .seconds(8))
        guard (200..<300).contains(Int(res.status.code)) else { return nil }
        return firstOpenSearchTitle(Data(buffer: try await res.body.collect(upTo: 256 * 1024)))
    }

    /// `["term", ["Title", …], [descriptions], [urls]]` → "Title".
    static func firstOpenSearchTitle(_ data: Data) -> String? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], arr.count > 1,
              let title = (arr[1] as? [String])?.first, !title.isEmpty else { return nil }
        return title
    }

    static func searchWikipedia(_ term: String, client: HTTPClient, logger: Logger) async -> WikiData? {
        do {
            var found = try await summary(term, client: client)
            if found == nil, let title = try await searchTitle(term, client: client) {
                found = try await summary(title, client: client)
            }
            guard let summary = found, summary.type != "disambiguation" else { return nil }

            var titles = ["en": summary.title]
            var categories: [String] = []
            let params = "action=query&titles=\(summary.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? summary.title)&prop=langlinks%7Ccategories&lllang=ja%7Cvi&cllimit=20&clshow=!hidden&format=json&origin=*"
            var wreq = HTTPClientRequest(url: "https://en.wikipedia.org/w/api.php?\(params)")
            wreq.headers.add(name: "user-agent", value: ua)
            if let wres = try? await client.execute(wreq, timeout: .seconds(8)),
               (200..<300).contains(Int(wres.status.code)),
               let obj = try? JSONSerialization.jsonObject(with: try await wres.body.collect(upTo: 512 * 1024)) as? [String: Any],
               let pages = (obj["query"] as? [String: Any])?["pages"] as? [String: Any],
               let page = pages.values.first as? [String: Any] {
                for ll in (page["langlinks"] as? [[String: Any]] ?? []) {
                    if ll["lang"] as? String == "ja", let t = ll["*"] as? String { titles["ja"] = t }
                    if ll["lang"] as? String == "vi", let t = ll["*"] as? String { titles["vi"] = t }
                }
                let deny = try! NSRegularExpression(pattern: "^(Articles|CS1|Webarchive|Wikipedia|Pages|All articles|Coordinates)", options: [.caseInsensitive])
                categories = (page["categories"] as? [[String: Any]] ?? [])
                    .compactMap { ($0["title"] as? String)?.replacingOccurrences(of: "Category:", with: "").trimmingCharacters(in: .whitespaces) }
                    .filter { deny.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
                    .prefix(10).map { $0 }
            }
            return WikiData(title: summary.title, description: summary.description ?? "",
                            extract: String((summary.extract ?? "").prefix(500)), titles: titles, categories: categories)
        } catch {
            logger.warning("Wikipedia search failed for '\(term)': \(error)")
            return nil
        }
    }

    static func parseWikiData(_ w: WikiData, cfg: OllamaService.Config, logger: Logger) async -> Parsed? {
        do {
            let input = String(data: try JSONSerialization.data(withJSONObject: [
                "en_title": w.title, "description": w.description, "extract": w.extract,
                "multilingual_titles": w.titles, "categories": w.categories,
            ]), encoding: .utf8) ?? "{}"
            let j = try await OllamaService.rawChatObject(cfg, system: parsePrompt, user: input, temperature: 0)
            guard let canonical = j["canonical_name"] as? String, !canonical.isEmpty,
                  let category = j["category"] as? String, !category.isEmpty else { return nil }
            return Parsed(canonicalName: canonical, category: category,
                          aliases: (j["aliases"] as? [Any])?.compactMap { $0 as? String } ?? [],
                          genreTags: (j["genre_tags"] as? [Any])?.compactMap { $0 as? String } ?? [])
        } catch {
            logger.warning("parseWikiData LLM failed: \(error)")
            return nil
        }
    }
}
