import Vapor
import NIOConcurrencyHelpers

/// One connected Socket.IO client. `rooms` is only mutated under `SocketHub`'s
/// lock. `ws.send` is itself thread-safe (WebSocketKit hops to the channel's
/// event loop), so `sendRaw` is safe to call from anywhere.
final class SocketConn: @unchecked Sendable {
    let sid: String
    let userID: String
    let ws: WebSocket
    fileprivate(set) var rooms: Set<String> = []

    init(sid: String, userID: String, ws: WebSocket) {
        self.sid = sid; self.userID = userID; self.ws = ws
    }
    func sendRaw(_ text: String) { ws.send(text, promise: nil) }
    var oid: ObjectIdentifier { ObjectIdentifier(self) }
}

/// In-memory connection registry + room fan-out + presence counter. Mirrors the
/// `io.to(room).emit(...)` / `onlineCounts` machinery in `backend/index.js`.
/// One instance, stored on `Application`.
final class SocketHub: @unchecked Sendable {
    private let lock = NIOLock()
    private var conns: [ObjectIdentifier: SocketConn] = [:]
    private var rooms: [String: Set<ObjectIdentifier>] = [:]
    private var online: [String: Int] = [:]

    // MARK: registry

    /// Register a freshly-authenticated connection and auto-join its `user:<id>` room.
    func add(_ c: SocketConn) {
        lock.withLock {
            conns[c.oid] = c
            rooms["user:\(c.userID)", default: []].insert(c.oid)
            c.rooms.insert("user:\(c.userID)")
        }
    }
    func remove(_ c: SocketConn) {
        lock.withLock {
            for r in c.rooms { rooms[r]?.remove(c.oid); if rooms[r]?.isEmpty == true { rooms[r] = nil } }
            conns[c.oid] = nil
        }
    }
    func join(_ c: SocketConn, _ room: String) {
        lock.withLock { rooms[room, default: []].insert(c.oid); c.rooms.insert(room) }
    }
    func leave(_ c: SocketConn, _ room: String) {
        lock.withLock { rooms[room]?.remove(c.oid); if rooms[room]?.isEmpty == true { rooms[room] = nil }; c.rooms.remove(room) }
    }

    // MARK: presence (userId → open-socket count)

    /// Returns true on the 0 → 1 transition (just came online).
    func incPresence(_ userID: String) -> Bool {
        lock.withLock { let n = online[userID, default: 0]; online[userID] = n + 1; return n == 0 }
    }
    /// Returns true on the 1 → 0 transition (just went offline).
    func decPresence(_ userID: String) -> Bool {
        lock.withLock {
            let n = (online[userID] ?? 1) - 1
            if n <= 0 { online[userID] = nil; return true }
            online[userID] = n; return false
        }
    }
    func isOnline(_ userID: String) -> Bool { lock.withLock { (online[userID] ?? 0) > 0 } }

    // MARK: fan-out

    private func targets(_ room: String, except: SocketConn?) -> [SocketConn] {
        lock.withLock {
            guard let ids = rooms[room] else { return [] }
            return ids.compactMap { conns[$0] }.filter { $0.oid != except?.oid }
        }
    }

    /// `io.to(room).emit(event, payload)`, encodes once, sends `42[event,payload]`
    /// to every socket in `room` (optionally excluding one sender socket).
    func emit<T: Encodable>(room: String, event: String, _ payload: T, except: SocketConn? = nil) {
        let frame = Self.eventFrame(event, SocketJSON.data(payload))
        for c in targets(room, except: except) { c.sendRaw(frame) }
    }
    /// `emitToUser(id, event, payload)`. The `user:<id>` room.
    func emitToUser<T: Encodable>(_ userID: String, event: String, _ payload: T) {
        emit(room: "user:\(userID)", event: event, payload)
    }
    /// Emit a pre-rendered JSON payload to `user:<id>` (notification DTOs are
    /// built as raw bytes by `NotificationsController.toDTOJSON`).
    func emitToUser(_ userID: String, event: String, rawJSON: Data) {
        let frame = Self.eventFrame(event, rawJSON)
        for c in targets("user:\(userID)", except: nil) { c.sendRaw(frame) }
    }
    /// Fan a chat mutation to the conversation room **and** every participant's
    /// personal room (the client dedupes by id). The exact pattern every Node
    /// chat handler uses.
    func emitConversation<T: Encodable>(_ conversationID: String, participants: [String], event: String, _ payload: T, exceptRoomSender: SocketConn? = nil) {
        emit(room: conversationID, event: event, payload, except: exceptRoomSender)
        for uid in participants { emitToUser(uid, event: event, payload) }
    }

    // MARK: frame builders

    static func eventFrame(_ event: String, _ payload: Data) -> String {
        "42[\"\(event)\"," + (String(data: payload, encoding: .utf8) ?? "null") + "]"
    }
    static func ackFrame(_ ackID: Int, _ payload: Data) -> String {
        "43\(ackID)[" + (String(data: payload, encoding: .utf8) ?? "null") + "]"
    }
}

enum SocketJSON {
    static let encoder = JSONCoding.makeEncoder()
    static func data<T: Encodable>(_ v: T) -> Data { (try? encoder.encode(v)) ?? Data("null".utf8) }
}

extension Application {
    private struct SocketHubKey: StorageKey { typealias Value = SocketHub }
    var socketHub: SocketHub {
        if let existing = storage[SocketHubKey.self] { return existing }
        let hub = SocketHub()
        storage[SocketHubKey.self] = hub
        return hub
    }
}
extension Request {
    var socketHub: SocketHub { application.socketHub }
}

// MARK: server→client payload shapes (exact key casing preserved from Node)

/// camelCase, presence / typing / read / delivered.
struct WSPresenceUpdate: Content { var userId: String; var online: Bool }
struct WSPresenceSnapshot: Content { var userIds: [String] }
struct WSMessagesRead: Content { var conversationId: String; var readBy: String }
struct WSUserTyping: Content { var userId: String; var isTyping: Bool }
/// socket path carries `userId`; the REST catch-up path omits it (see controller).
struct WSMessageDelivered: Content { var conversationId: String; var messageId: String; var userId: String? }

/// snake_case, chat mutations.
struct WSReactionUpdated: Content { var conversation_id: String; var message_id: String; var reactions: [String: [String]] }
struct WSMeetingProposal: Content {
    var conversation_id: String; var message_id: String
    @NullCoded var meeting_proposal: MessageObject.MeetingProposal?
}
/// `poll_updated`: a vote changed a poll's counts and voters.
struct WSPoll: Content {
    var conversation_id: String; var message_id: String
    var poll: MessageObject.Poll
}
struct WSMessageDeleted: Content { var conversation_id: String; var message_id: String }
struct WSPinAdded: Content { var conversation_id: String; var message_id: String; var pins: [ChatStore.PinRow] }
struct WSPinRemoved: Content { var conversation_id: String; var message_id: String }
struct WSMemberAdded: Content { var conversation_id: String; var added_user_ids: [String]; var members: [ChatStore.GroupSettings.GroupMember] }
struct WSMemberRemoved: Content { var conversation_id: String; var removed_user_id: String }
struct WSGroupUpdated: Content {
    var conversation_id: String
    @NullCoded var name: String?
    @NullCoded var avatar_url: String?
    @NullCoded var avatar_color: String?
    var new_owner_id: String?
}
struct WSGroupSettingsUpdated: Content { var conversation_id: String; @NullCoded var theme: String? }
struct WSDirectSettingsUpdated: Content {
    var conversation_id: String
    @NullCoded var theme: String?
    var nickname_target_id: String
    @NullCoded var nickname: String?
}
