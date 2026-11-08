import Vapor
import AsyncHTTPClient

/// OpenAI's moderation endpoint: free, and kept to the cases the local check is
/// unsure about (and, in the next phase, to photos). Text goes to OpenAI only
/// when `OPENAI_API_KEY` is set; chat messages never do. The endpoint keeps no
/// abuse-monitoring logs of what it is sent (OpenAI's data-controls guide).
enum OpenAIModeration {
    struct Result: Equatable, Sendable {
        let flagged: Bool
        /// The categories it flagged, e.g. "harassment/threatening".
        let categories: [String]
        let scores: [String: Double]
    }

    static func parse(_ data: Data) -> Result? {
        struct Body: Decodable {
            struct Item: Decodable { let flagged: Bool; let categories: [String: Bool]; let category_scores: [String: Double]? }
            let results: [Item]
        }
        guard let item = (try? JSONDecoder().decode(Body.self, from: data))?.results.first else { return nil }
        return Result(flagged: item.flagged, categories: item.categories.filter(\.value).keys.sorted(),
                      scores: item.category_scores ?? [:])
    }

    /// OpenAI's category names mapped onto this app's rules.
    static func policy(for category: String) -> ModerationPolicy? {
        switch category {
        case "sexual/minors": .childSafety
        case "sexual": .nuditySexual
        case "violence", "violence/graphic", "harassment/threatening", "hate/threatening": .violence
        case "self-harm", "self-harm/intent", "self-harm/instructions": .selfHarm
        case "hate": .hate
        case "harassment": .harassment
        case "illicit", "illicit/violent": .illegalGoods
        default: nil
        }
    }

    static func check(text: String, key: String, model: String, client: HTTPClient) async throws -> Result {
        var req = HTTPClientRequest(url: "https://api.openai.com/v1/moderations")
        req.method = .POST
        req.headers.add(name: "content-type", value: "application/json")
        req.headers.add(name: "authorization", value: "Bearer \(key)")
        req.body = .bytes(try JSONSerialization.data(withJSONObject: ["model": model, "input": String(text.prefix(4000))]))
        let res = try await client.execute(req, timeout: .seconds(20))
        guard (200..<300).contains(Int(res.status.code)) else {
            throw Abort(.badGateway, reason: "OpenAI moderation error: \(res.status.code)")
        }
        let buf = try await res.body.collect(upTo: 1024 * 1024)
        guard let result = parse(Data(buffer: buf)) else { throw Abort(.badGateway, reason: "Unreadable OpenAI answer") }
        return result
    }

    /// A photo, as a data URL (OpenAI reads sexual, violence, graphic violence
    /// and self-harm in images — not minors, which stays a report's job).
    static func checkImage(_ data: Data, mime: String, key: String, model: String, client: HTTPClient) async throws -> Result {
        let url = "data:\(mime);base64,\(data.base64EncodedString())"
        let body: [String: Any] = ["model": model, "input": [["type": "image_url", "image_url": ["url": url]]]]
        var req = HTTPClientRequest(url: "https://api.openai.com/v1/moderations")
        req.method = .POST
        req.headers.add(name: "content-type", value: "application/json")
        req.headers.add(name: "authorization", value: "Bearer \(key)")
        req.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        let res = try await client.execute(req, timeout: .seconds(30))
        guard (200..<300).contains(Int(res.status.code)) else {
            throw Abort(.badGateway, reason: "OpenAI moderation error: \(res.status.code)")
        }
        let buf = try await res.body.collect(upTo: 1024 * 1024)
        guard let result = parse(Data(buffer: buf)) else { throw Abort(.badGateway, reason: "Unreadable OpenAI answer") }
        return result
    }
}
