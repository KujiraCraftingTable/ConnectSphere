import Vapor
import SQLKit

/// `/api/hidden-contacts?mode=`, people the signed-in user hid from the
/// Messages people row (see `HiddenContactStore`).
struct HiddenContactsController {
    static func register(routes: any RoutesBuilder) {
        let h = routes.grouped("hidden-contacts").grouped(AuthMiddleware())
        h.get(use: list)
        h.put(":userId", use: hide)
        h.delete(":userId", use: unhide)
    }

    struct OK: Content { var ok: Bool }

    static func list(_ req: Request) async throws -> DataListResponse<HiddenContactStore.Contact> {
        let mode = try validMode(req)
        return DataListResponse(data: try await HiddenContactStore.list(owner: req.userID, mode: mode, on: req.db.sql()))
    }

    static func hide(_ req: Request) async throws -> OK {
        let mode = try validMode(req)
        let other = try userID(req)
        guard other != req.userID else { throw InlineError(.badRequest, "You can't hide yourself") }
        let db = req.db.sql()
        guard try await HiddenContactStore.userExists(other, on: db) else {
            throw InlineError(.notFound, "User not found")
        }
        try await HiddenContactStore.hide(owner: req.userID, hidden: other, mode: mode, on: db)
        return OK(ok: true)
    }

    static func unhide(_ req: Request) async throws -> OK {
        let mode = try validMode(req)
        try await HiddenContactStore.unhide(owner: req.userID, hidden: try userID(req), mode: mode, on: req.db.sql())
        return OK(ok: true)
    }

    private static func validMode(_ req: Request) throws -> String {
        guard let mode = try? req.query.get(String.self, at: "mode"), HiddenContactStore.modes.contains(mode) else {
            throw InlineError(.badRequest, "mode must be hobby or work")
        }
        return mode
    }

    private static func userID(_ req: Request) throws -> String {
        guard let raw = req.parameters.get("userId"), let uuid = UUID(uuidString: raw) else {
            throw InlineError(.badRequest, "Invalid user id")
        }
        return uuid.uuidString.lowercased()
    }
}
