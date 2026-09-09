import Vapor
import SQLKit

/// Port of `backend/src/routes/messageRoutes.js` + `messageController.js` +
/// the core of `messageService.js` / `messageModel.js`. Error bodies use the
/// `{status,code,message}` shape (the Node controller's inline errors carry
/// `code`; `clientError` in the service goes through the central handler).
///
/// This slice (4a): conversations open/list, messages list/send/recall,
/// react, read/delivered/unread, clear, settings/mute/media/search, pins.
/// Group management + meeting-proposal REST + the Socket.IO fan-out are the
/// next Phase 4 slices — those routes 501 until then.
struct MessagesController {
    static func register(routes: any RoutesBuilder) {
        let up = routes.grouped("messages")
        up.grouped(AuthMiddleware()).on(.POST, "upload", body: .collect(maxSize: "50mb"), use: upload)

        let m = routes.grouped("messages").grouped(AuthMiddleware())
        m.post("conversations", use: openConversation)
        m.post("conversations", "group", use: notImplemented)
        m.get("conversations", use: listConversations)
        m.get("conversations", ":id", "settings", use: getSettings)
        m.patch("conversations", ":id", "settings", use: notImplemented)
        m.put("conversations", ":id", "mute", use: setMute)
        m.get("conversations", ":id", "media", use: listMedia)
        m.get("conversations", ":id", "messages", "search", use: searchMessages)
        m.get("conversations", ":id", "pins", use: listPins)
        m.post("conversations", ":id", "pins", use: pinMessage)
        m.delete("conversations", ":id", "pins", ":messageId", use: unpinMessage)
        m.post("conversations", ":id", "members", use: notImplemented)
        m.delete("conversations", ":id", "members", ":userId", use: notImplemented)
        m.post("conversations", ":id", "members", ":userId", "promote", use: notImplemented)
        m.patch("conversations", ":id", "group", use: notImplemented)
        m.post("conversations", ":id", "leave", use: notImplemented)
        m.get("conversations", ":id", "block-alert-state", use: blockAlertState)
        m.post("conversations", ":id", "block-alert-ack", use: notImplemented)
        m.get("conversations", ":id", "messages", use: listMessages)
        m.post("conversations", ":id", "messages", use: sendMessage)
        m.delete("conversations", ":id", "messages", use: clearConversation)
        m.delete("conversations", ":id", "messages", ":messageId", use: recallMessage)
        m.post("conversations", ":id", "messages", ":messageId", "reactions", use: reactToMessage)
        m.patch("conversations", ":id", "messages", ":messageId", "meeting-proposal", use: notImplemented)
        m.post("conversations", ":id", "messages", ":messageId", "meeting-proposal", "cancel", use: notImplemented)
        m.post("conversations", ":id", "messages", ":messageId", "meeting-response", use: notImplemented)
        m.put("conversations", ":id", "read", use: markRead)
        m.put("conversations", ":id", "delivered", use: markDelivered)
        m.get("unread", use: unreadCount)
    }

    static func notImplemented(_ req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "ported in a later Phase 4 slice")
    }

    static func requireParticipant(_ conversationID: String, _ req: Request) async throws {
        guard try await ChatStore.isParticipant(conversationID, req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
    }

    // MARK: upload

    struct UploadResult: Content { var data: Inner; struct Inner: Content { var url: String; var message_type: String } }
    static let uploadDir = "../backend/uploads/messages"
    static let extByMime: [String: String] = [
        "image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
        "video/mp4": ".mp4", "video/quicktime": ".mov", "audio/m4a": ".m4a",
    ]
    static func upload(_ req: Request) async throws -> UploadResult {
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file,
              let mime = file.contentType.map({ "\($0.type)/\($0.subType)" }),
              let ext = extByMime[mime] else {
            throw Abort(.badRequest, reason: "Invalid or missing file")
        }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())\(ext)"
        try FileManager.default.createDirectory(atPath: uploadDir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(file.data, at: "\(uploadDir)/\(name)")
        let type = mime.hasPrefix("video/") ? "video" : (mime.hasPrefix("audio/") ? "voice" : "image")
        return UploadResult(data: .init(url: "/uploads/messages/\(name)", message_type: type))
    }

    // MARK: conversations

    struct OpenBody: Content { var other_user_id: String?; var mode: String? }
    struct IDData: Content { var data: Inner; struct Inner: Content { var id: String } }
    static func openConversation(_ req: Request) async throws -> IDData {
        let b = try req.content.decode(OpenBody.self)
        guard let other = b.other_user_id, let mode = b.mode else {
            throw Abort(.badRequest, reason: "other_user_id and mode are required")
        }
        if req.userID == other { throw Abort(.badRequest, reason: "Cannot start a conversation with yourself") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }
        if try await UserStore.isBlockedEitherWay(req.userID, other, on: req.db.sql()) {
            throw Abort(.forbidden, reason: "Cannot message this user")
        }
        if let existing = try await ChatStore.findConversation(req.userID, other, mode: mode, on: req.db.sql()) {
            return IDData(data: .init(id: existing))
        }
        let id = try await ChatStore.createConversation(req.userID, other, mode: mode, on: req.db)
        return IDData(data: .init(id: id))
    }

    static func listConversations(_ req: Request) async throws -> DataListResponse<ChatStore.ConversationSummary> {
        guard let mode = try? req.query.get(String.self, at: "mode") else { throw Abort(.badRequest, reason: "mode is required") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }
        return DataListResponse(data: try await ChatStore.listConversations(req.userID, mode: mode, on: req.db.sql()))
    }

    // MARK: messages

    static func listMessages(_ req: Request) async throws -> DataListResponse<MessageObject> {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 30
        let before = try? req.query.get(String.self, at: "before")
        return DataListResponse(data: try await ChatStore.listMessages(id, userID: req.userID, limit: limit, before: before, on: req.db.sql()))
    }

    struct SendBody: Content {
        var content: String?
        var message_type: String?
        var media_url: String?
        var reply_to_message_id: String?
        var voice_duration_seconds: Int?
        var voice_waveform: [Double]?
        // meeting_proposal handled in slice 4b
    }
    static func sendMessage(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let b = try req.content.decode(SendBody.self)
        let type = b.message_type ?? "text"
        if type == "meeting" { throw Abort(.notImplemented, reason: "meeting messages ported in a later Phase 4 slice") }
        if type == "text", (b.content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            throw Abort(.badRequest, reason: "Message content is required")
        }
        if ["image", "video", "voice"].contains(type), b.media_url == nil {
            throw Abort(.badRequest, reason: "Media URL is required")
        }
        if let c = b.content, c.count > 2000 { throw Abort(.badRequest, reason: "Message is too long") }

        var replyTo: String? = nil
        if let rid = b.reply_to_message_id {
            guard let target = try await ChatStore.messageBasic(rid, on: db), target.conversation_id == id else {
                throw Abort(.badRequest, reason: "Message being replied to was not found in this conversation")
            }
            replyTo = rid
        }
        // 1:1 block check (groups: warning only, skipped here)
        let parts = try await ChatStore.participants(id, on: db)
        if parts.count <= 2, let other = parts.first(where: { $0 != req.userID }),
           try await UserStore.isBlockedEitherWay(req.userID, other, on: db) {
            throw Abort(.forbidden, reason: "Cannot message this user")
        }
        let newID = try await ChatStore.insertMessage(id, senderID: req.userID,
            content: b.content?.trimmingCharacters(in: .whitespaces).nilIfEmpty, messageType: type,
            mediaUrl: b.media_url, replyToMessageID: replyTo,
            voiceDuration: b.voice_duration_seconds, voiceWaveform: b.voice_waveform, on: db)
        guard let msg = try await ChatStore.messageByID(newID, on: db) else { throw Abort(.internalServerError) }
        // TODO(4c): emit new_message; (4b) notifyNewMessage inbox row
        return try await ConnectionsController.encode(DataResponse(data: msg), req, .created)
    }

    struct StatusOK: Content { var status = "ok" }

    static func recallMessage(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        try await requireParticipant(id, req)
        _ = try await ChatStore.recall(mid, conversationID: id, senderID: req.userID, on: req.db.sql())
        // TODO(4c): message_deleted emit
        return StatusOK()
    }

    struct ReactBody: Content { var emoji: String? }
    struct ReactionsResponse: Content { var data: Inner; struct Inner: Content { var reactions: [String: [String]] } }
    static func reactToMessage(_ req: Request) async throws -> ReactionsResponse {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let emoji = try req.content.decode(ReactBody.self).emoji else { throw Abort(.badRequest, reason: "emoji is required") }
        guard ChatStore.reactionEmoji.contains(emoji) else { throw Abort(.badRequest, reason: "Unsupported emoji") }
        guard let target = try await ChatStore.messageBasic(mid, on: db), target.conversation_id == id else {
            throw Abort(.notFound, reason: "Message not found")
        }
        let parts = try await ChatStore.participants(id, on: db)
        if parts.count <= 2, let other = parts.first(where: { $0 != req.userID }),
           try await UserStore.isBlockedEitherWay(req.userID, other, on: db) {
            throw Abort(.forbidden, reason: "Cannot message this user")
        }
        let reactions = try await ChatStore.setReaction(mid, userID: req.userID, emoji: emoji, on: db)
        return ReactionsResponse(data: .init(reactions: reactions))
    }

    static func markRead(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        _ = try await ChatStore.markRead(id, userID: req.userID, on: req.db.sql())
        // TODO(4c): emit messages_read (folded fix — REST path must emit too)
        return StatusOK()
    }

    static func markDelivered(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        _ = try await ChatStore.markConversationDelivered(id, userID: req.userID, on: req.db.sql())
        // TODO(4c): emit message_delivered per sender
        return StatusOK()
    }

    struct CountData: Content { var data: Inner; struct Inner: Content { var count: Int } }
    static func unreadCount(_ req: Request) async throws -> CountData {
        guard let mode = try? req.query.get(String.self, at: "mode") else { throw Abort(.badRequest, reason: "mode is required") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }
        return CountData(data: .init(count: try await ChatStore.totalUnread(req.userID, mode: mode, on: req.db.sql())))
    }

    static func clearConversation(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        try await ChatStore.clearConversation(id, userID: req.userID, on: req.db.sql())
        return StatusOK()
    }

    // MARK: settings / mute / media / search

    struct SettingsData<T: Content>: Content { var data: T }
    static func getSettings(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let conv = try await ChatStore.conversationByID(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
        if conv.is_group {
            guard let s = try await ChatStore.groupSettings(id, userID: req.userID, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
            return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
        } else {
            guard let s = try await ChatStore.settings1to1(id, userID: req.userID, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
            return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
        }
    }

    struct MuteBody: Content { var minutes: Int? }
    struct MuteData: Content { var data: Inner; struct Inner: Content { @NullCoded var muted_until: Date? } }
    static func setMute(_ req: Request) async throws -> MuteData {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        var value: Int? = nil
        if let m = try req.content.decode(MuteBody.self).minutes { value = m < 0 ? -1 : min(m, 43200) }
        let until = try await ChatStore.setMute(id, userID: req.userID, minutes: value, on: req.db.sql())
        return MuteData(data: .init(muted_until: until))
    }

    static func listMedia(_ req: Request) async throws -> DataListResponse<ChatStore.MediaItem> {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        return DataListResponse(data: try await ChatStore.media(id, userID: req.userID, on: req.db.sql()))
    }
    static func searchMessages(_ req: Request) async throws -> DataListResponse<SearchMessageObject> {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        let term = (try? req.query.get(String.self, at: "q")) ?? ""
        return DataListResponse(data: try await ChatStore.searchMessages(id, userID: req.userID, term: term, on: req.db.sql()))
    }

    // MARK: pins

    static func listPins(_ req: Request) async throws -> DataListResponse<ChatStore.PinRow> {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        return DataListResponse(data: try await ChatStore.listPins(id, on: req.db.sql()))
    }
    struct PinBody: Content { var message_id: String?; var expires_at: String? }
    static func pinMessage(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let mid = try req.content.decode(PinBody.self).message_id else { throw Abort(.badRequest, reason: "message_id is required") }
        let expiresAt = try req.content.decode(PinBody.self).expires_at
        guard let target = try await ChatStore.messageBasic(mid, on: db), target.conversation_id == id else {
            throw Abort(.notFound, reason: "Message not found")
        }
        guard let pin = try await ChatStore.pinMessage(id, messageID: mid, userID: req.userID, expiresAt: expiresAt, on: db) else {
            throw Abort(.badRequest, reason: "This conversation already has \(ChatStore.maxPins) pinned messages")
        }
        // TODO(4c): pin_added emit
        return try await ConnectionsController.encode(DataResponse(data: pin), req, .created)
    }
    struct UnpinData: Content { var data: Inner; struct Inner: Content { var unpinned = true } }
    static func unpinMessage(_ req: Request) async throws -> UnpinData {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        try await requireParticipant(id, req)
        guard try await ChatStore.unpinMessage(id, messageID: mid, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Pin not found")
        }
        return UnpinData(data: .init())
    }

    // MARK: block-alert (group-only; 1:1 → { shouldAlert: false })

    struct BlockAlertData: Content { var data: Inner; struct Inner: Content { var shouldAlert = false; @NullCoded var blockedUserIds: [String]? } }
    static func blockAlertState(_ req: Request) async throws -> BlockAlertData {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        // Full group block-alert logic lands in slice 4b; 1:1 always false.
        return BlockAlertData(data: .init())
    }
}
