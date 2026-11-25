import Vapor
import AsyncHTTPClient

/// The local text check: Qwen3Guard-Gen, a small safety model, served by the
/// app's own Ollama so nothing leaves the server. It answers "Safe",
/// "Controversial" (depends on context) or "Unsafe" with the categories.
///
/// The prompt is sent raw: the GGUF builds on Hugging Face ship a chat
/// template that judges the text as an assistant's *reply*, which calls every
/// message unsafe (even a greeting). This is Qwen's own "user message" prompt.
enum LocalGuard {
    // MARK: - Verdicts
    enum Level: String, Sendable { case safe, controversial, unsafe }

    struct Verdict: Equatable, Sendable {
        let level: Level
        /// As the model names them: "Violent", "Sexual Content or Sexual Acts"…
        let categories: [String]
    }

    private static let prompt = """
        <|im_start|>user
        # Task:
        1) Evaluate whether THE LAST USER's query belongs to safe or unsafe content based on our safety policy.
        2) Identify the category of unsafe content found.

        <BEGIN SAFETY POLICY>
        **Safety: Safe**: The USER's query does not contain any prohibited content or content that could lead to prohibited content.
        **Safety: Unsafe**: The USER's query contains prohibited content.
        **Safety: Controversial**: The USER's query does not explicitly contain prohibited content, but its intent, context, or potential responses could be misinterpreted, misused, or exploited to generate unsafe content under certain conditions.
        <END SAFETY POLICY>

        <BEGIN UNSAFE CONTENT CATEGORIES>
        Violent.
        Non-violent Illegal Acts.
        Sexual Content or Sexual Acts.
        PII.
        Suicide & Self-Harm.
        Unethical Acts.
        Politically Sensitive Topics.
        Copyright Violation.
        Jailbreak.
        <END UNSAFE CONTENT CATEGORIES>

        <BEGIN CONVERSATION>

        USER: %@

        <END CONVERSATION>

        Provide your safety assessment for ONLY THE LAST **USER's query** in the above conversation:
         - The first line must be one of: 'Safety: Safe', 'Safety: Unsafe', 'Safety: Controversial'.
         - The second line should start with 'Categories:' followed by a list of any unsafe content categories, separated by commas. If the content is safe, use 'Categories: None'.<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """

    // MARK: - Parsing
    /// "Safety: Unsafe\nCategories: Violent, PII" → a verdict; nil if it isn't that shape.
    static func parse(_ raw: String) -> Verdict? {
        var level: Level?
        var categories: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("safety:") {
                level = Level(rawValue: l.dropFirst("safety:".count).trimmingCharacters(in: .whitespaces).lowercased())
            } else if l.lowercased().hasPrefix("categories:") {
                categories = l.dropFirst("categories:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.lowercased() != "none" }
            }
        }
        guard let level else { return nil }
        return Verdict(level: level, categories: categories)
    }

    /// The categories that mean something for this app. Politics, copyright
    /// and jailbreaks aren't rules here; PII (a phone number in a listing) is
    /// ordinary in a marketplace, so it isn't one either.
    static func policy(for category: String) -> ModerationPolicy? {
        switch category.lowercased() {
        case "violent": .violence
        case "sexual content or sexual acts": .nuditySexual
        case "suicide & self-harm": .selfHarm
        case "non-violent illegal acts": .illegalGoods
        case "unethical acts": .harassment
        default: nil
        }
    }

    // MARK: - Classification
    static func classify(_ text: String, model: String, ollama: OllamaService.Config) async throws -> Verdict {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt.replacingOccurrences(of: "%@", with: String(text.prefix(2000))),
            "raw": true,
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0, "num_predict": 40],
        ]
        var req = HTTPClientRequest(url: "\(ollama.url)/api/generate")
        req.method = .POST
        req.headers.add(name: "content-type", value: "application/json")
        req.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        let res = try await OllamaGate.run { try await ollama.client.execute(req, timeout: .seconds(60)) }
        guard (200..<300).contains(Int(res.status.code)) else {
            throw Abort(.badGateway, reason: "Ollama error: \(res.status.code)")
        }
        let buf = try await res.body.collect(upTo: 1024 * 1024)
        struct R: Decodable { let response: String? }
        let raw = (try? JSONDecoder().decode(R.self, from: buf))?.response ?? ""
        guard let verdict = parse(raw) else { throw Abort(.badGateway, reason: "Unreadable guard answer: \(raw.prefix(80))") }
        return verdict
    }
}
