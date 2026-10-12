import Vapor
import AsyncHTTPClient
import NIOCore

/// Anything that can turn text from one language into another. The
/// translation pipeline only ever talks to this, so a model built for
/// translation can replace today's general chat model without touching the
/// rest (language detection, storage, jobs).
protocol Translator: Sendable {
    /// `from` / `to` are "en" or "vi".
    func translate(_ text: String, from: String, to: String) async throws -> String
}

enum Translators {
    /// The configured translator, or nil when translation is switched off.
    static func make(_ app: Application) -> (any Translator)? {
        let cfg = app.appEnv.translation
        guard cfg.enabled else { return nil }
        return OllamaChatTranslator(url: cfg.url, model: cfg.model,
                                    timeout: .seconds(Int64(cfg.timeoutSeconds)), client: app.http.client.shared)
    }

    static func languageName(_ code: String) -> String { code == "vi" ? "Vietnamese" : "English" }
}

/// Translation through an Ollama chat model (today the same qwen2.5 the AI
/// search uses, until a translation-only model is picked — see
/// TRANSLATION_MODEL). It has its own prompt and request, separate from
/// `OllamaService`'s search prompts.
struct OllamaChatTranslator: Translator {
    let url: String
    let model: String
    let timeout: TimeAmount
    let client: HTTPClient

    static func systemPrompt(from: String, to: String) -> String {
        """
        You translate social media posts and comments from \(Translators.languageName(from)) to \(Translators.languageName(to)).
        Translate faithfully and naturally. Do not add, explain, summarise or answer anything.
        Keep names of people, brands, places, dishes and foods exactly as written — never swap in a local equivalent.
        Keep emojis, #hashtags, @mentions, URLs and line breaks unchanged.
        Reply with the translation only.
        """
    }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(from: from, to: to)],
                ["role": "user", "content": text],
            ],
            "options": ["temperature": 0],
            "stream": false,
            "keep_alive": "10m",
        ]
        var req = HTTPClientRequest(url: "\(url)/api/chat")
        req.method = .POST
        req.headers.add(name: "content-type", value: "application/json")
        req.body = .bytes(try JSONSerialization.data(withJSONObject: body))
        let res = try await client.execute(req, timeout: timeout)
        guard (200..<300).contains(Int(res.status.code)) else {
            throw Abort(.badGateway, reason: "Translation model error: \(res.status.code)")
        }
        let buf = try await res.body.collect(upTo: 1024 * 1024)
        struct R: Decodable { struct M: Decodable { let content: String? }; let message: M? }
        let raw = (try? JSONDecoder().decode(R.self, from: buf))?.message?.content ?? ""
        return TranslationService.cleanOutput(raw, source: text)
    }
}
