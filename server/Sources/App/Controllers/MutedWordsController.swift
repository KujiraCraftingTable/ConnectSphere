import Vapor
import SQLKit

/// `/api/muted-words` — the signed-in user's muted words, one list per mode
/// (see `MutedWordStore`). Another user's word id behaves like a missing one.
struct MutedWordsController {
    static func register(routes: any RoutesBuilder) {
        let m = routes.grouped("muted-words").grouped(AuthMiddleware())
        m.get(use: list)
        m.post(use: add)
        m.post("copy", use: copy)
        m.delete(":id", use: delete)
    }

    struct ListResponse: Content { var data: [MutedWordStore.Word] }
    struct OK: Content { var ok: Bool }
    struct CopyResponse: Content { var added: Int }

    static func list(_ req: Request) async throws -> ListResponse {
        let mode = try validMode(try? req.query.get(String.self, at: "mode"))
        return ListResponse(data: try await MutedWordStore.list(owner: req.userID, mode: mode, on: req.db.sql()))
    }

    struct AddBody: Content { var mode: String?; var word: String?; var duration: String? }

    static func add(_ req: Request) async throws -> MutedWordStore.Word {
        let b = try req.content.decode(AddBody.self)
        let mode = try validMode(b.mode)
        guard let word = MutedWordStore.cleanWord(b.word) else {
            throw InlineError(.badRequest, "A muted word needs 1–\(MutedWordStore.maxLength) characters, including a letter or number")
        }
        guard let seconds = MutedWordStore.durations[b.duration ?? "forever"] else {
            throw InlineError(.badRequest, "Unknown duration")
        }
        let db = req.db.sql()
        guard try await MutedWordStore.count(owner: req.userID, mode: mode, on: db) < MutedWordStore.maxWordsPerMode else {
            throw InlineError(.badRequest, "You can mute up to \(MutedWordStore.maxWordsPerMode) words")
        }
        return try await MutedWordStore.add(owner: req.userID, mode: mode, word: word, seconds: seconds, on: db)
    }

    static func delete(_ req: Request) async throws -> OK {
        guard let id = UUID(uuidString: req.parameters.get("id") ?? ""),
              try await MutedWordStore.delete(id.uuidString, owner: req.userID, on: req.db.sql()) else {
            throw InlineError(.notFound, "Muted word not found")
        }
        return OK(ok: true)
    }

    struct CopyBody: Content { var from: String?; var to: String? }

    static func copy(_ req: Request) async throws -> CopyResponse {
        let b = try req.content.decode(CopyBody.self)
        let from = try validMode(b.from), to = try validMode(b.to)
        guard from != to else { throw InlineError(.badRequest, "Choose the other mode to copy to") }
        let db = req.db.sql()
        let incoming = try await MutedWordStore.count(owner: req.userID, mode: from, on: db)
        let existing = try await MutedWordStore.count(owner: req.userID, mode: to, on: db)
        guard incoming + existing <= MutedWordStore.maxWordsPerMode else {
            throw InlineError(.badRequest, "You can mute up to \(MutedWordStore.maxWordsPerMode) words")
        }
        return CopyResponse(added: try await MutedWordStore.copy(owner: req.userID, from: from, to: to, on: db))
    }

    static func validMode(_ raw: String?) throws -> String {
        guard let mode = raw, MutedWordStore.modes.contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        return mode
    }
}
