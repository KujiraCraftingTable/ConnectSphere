import Foundation
import XCTest

/// The UI-test server's `/api/test` routes (`TestHooksController`): throwaway
/// accounts, emailed codes, and deleting a run's accounts afterwards.
///
/// Reads `UITEST_SERVER` (default `http://localhost:3001`) and `UITEST_TOKEN`
/// from the test runner's environment; `scripts/uitest.sh` passes both as
/// `TEST_RUNNER_*` build settings.
struct TestServer {
    struct Account: Decodable {
        let id: String
        let username: String
        let password: String
        let email: String?
        let token: String
    }

    enum Kind: String { case basic, twoFactor = "two_factor", verifiedEmail = "verified_email" }

    static let shared = TestServer()

    let base: URL
    private let token: String

    private init() {
        let env = ProcessInfo.processInfo.environment
        base = URL(string: env["UITEST_SERVER"] ?? "http://localhost:3001")!
        token = env["UITEST_TOKEN"] ?? ""
    }

    var serverURL: String { base.absoluteString }

    /// `bio` and `interests`, when given, go on every account made: a search fixture.
    func createAccounts(run: String, kind: Kind = .basic, count: Int = 1,
                        bio: String? = nil, interests: [String]? = nil) async throws -> [Account] {
        var json: [String: Any] = ["run_id": run, "kind": kind.rawValue, "count": count]
        json["bio"] = bio
        json["interests"] = interests
        let body = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode([Account].self, from: try await send("POST", "users", body: body))
    }

    /// Builds the run's profile embeddings now (the test server runs no jobs),
    /// so AI search can find them. Returns how many were built.
    @discardableResult
    func embedRun(_ run: String) async throws -> Int {
        struct Embedded: Decodable { let built: Int }
        return try JSONDecoder().decode(Embedded.self, from: try await send("POST", "runs/\(run)/embed")).built
    }

    func createAccount(run: String, kind: Kind = .basic) async throws -> Account {
        try await createAccounts(run: run, kind: kind, count: 1)[0]
    }

    /// The last code mailed to `email`. Codes go out while the request that
    /// asked for them is still running, so this is only called after the app
    /// shows its code screen.
    func lastCode(for email: String) async throws -> String {
        var url = URLComponents(url: base.appending(path: "api/test/last-code"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "email", value: email)]
        struct Code: Decodable { let code: String }
        return try JSONDecoder().decode(Code.self, from: try await send("GET", url: url.url!)).code
    }

    @discardableResult
    func deleteRun(_ run: String) async throws -> Int {
        struct Deleted: Decodable { let users: Int }
        return try JSONDecoder().decode(Deleted.self, from: try await send("DELETE", "runs/\(run)")).users
    }

    /// Makes `account` a verified recruiter whose jobs go live without review.
    func makeRecruiter(_ account: Account) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["user_id": account.id])
        _ = try await send("POST", "recruiters", body: body)
    }

    /// A public Hobby community owned by `owner`; returns its id.
    func createCommunity(owner: Account, name: String) async throws -> String {
        struct Created: Decodable { let id: String }
        let body = try JSONSerialization.data(withJSONObject: ["user_id": owner.id, "name": name])
        return try JSONDecoder().decode(Created.self, from: try await send("POST", "communities", body: body)).id
    }

    // MARK: The real API, acting as a test account (the other side of a chat, a post's author)

    /// Posts a public text post as `account` and returns its id.
    func createPost(as account: Account, content: String, mode: String = "hobby") async throws -> String {
        struct Created: Decodable { struct Post: Decodable { let id: String }; let data: Post }
        let data = try await api("POST", "posts", as: account, json: ["content": content, "mode": mode, "privacy": "public"])
        return try JSONDecoder().decode(Created.self, from: data).data.id
    }

    /// A remote Work job posted by `recruiter` (see `makeRecruiter`); returns the post id.
    func createJob(as recruiter: Account, title: String) async throws -> String {
        struct Created: Decodable { struct Post: Decodable { let id: String }; let data: Post }
        let data = try await api("POST", "posts", as: recruiter, json: [
            "content": "QA job: \(title)", "mode": "work", "privacy": "public", "post_type": "job",
            "jobData": ["title": title, "careersUrl": "https://example.test/careers", "workFormat": "remote"],
        ])
        return try JSONDecoder().decode(Created.self, from: data).data.id
    }

    /// `a` asks, `b` accepts: connected in `mode` (their chats skip Waiting).
    func connect(_ a: Account, _ b: Account, mode: String = "hobby") async throws {
        struct Requested: Decodable { let connection_id: String }
        let data = try await api("POST", "connections/request", as: a, json: ["addressee_id": b.id, "mode": mode])
        let id = try JSONDecoder().decode(Requested.self, from: data).connection_id
        try await api("POST", "connections/accept", as: b, json: ["connection_id": id])
    }

    /// Opens (or finds) the 1:1 chat between `account` and `other`, returns its id.
    func openConversation(as account: Account, with other: Account, mode: String = "hobby") async throws -> String {
        struct Opened: Decodable { struct Conversation: Decodable { let id: String }; let data: Conversation }
        let data = try await api("POST", "messages/conversations", as: account,
                                 json: ["other_user_id": other.id, "mode": mode])
        return try JSONDecoder().decode(Opened.self, from: data).data.id
    }

    func sendMessage(as account: Account, conversation: String, content: String) async throws {
        try await api("POST", "messages/conversations/\(conversation)/messages", as: account, json: ["content": content])
    }

    @discardableResult
    private func api(_ method: String, _ path: String, as account: Account, json: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "api/\(path)"), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    struct HTTPError: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? { "test server answered \(status): \(body)" }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try await send(method, url: base.appending(path: "api/test/\(path)"), body: body)
    }

    private func send(_ method: String, url: URL, body: Data? = nil) async throws -> Data {
        guard !token.isEmpty else {
            throw XCTSkip("UITEST_TOKEN is not set; run the suite with scripts/uitest.sh")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-UITest-Token")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
