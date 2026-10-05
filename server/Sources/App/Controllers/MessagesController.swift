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
        m.post("conversations", "group", use: createGroupConversation)
        m.get("conversations", use: listConversations)
        m.get("conversations", ":id", "settings", use: getSettings)
        m.patch("conversations", ":id", "settings", use: updateSettings)
        m.put("conversations", ":id", "mute", use: setMute)
        m.get("conversations", ":id", "media", use: listMedia)
        m.get("conversations", ":id", "messages", "search", use: searchMessages)
        m.get("conversations", ":id", "pins", use: listPins)
        m.post("conversations", ":id", "pins", use: pinMessage)
        m.delete("conversations", ":id", "pins", ":messageId", use: unpinMessage)
        m.post("conversations", ":id", "members", use: addMembers)
        m.delete("conversations", ":id", "members", ":userId", use: removeMember)
        m.post("conversations", ":id", "members", ":userId", "promote", use: promoteOwner)
        m.patch("conversations", ":id", "group", use: updateGroup)
        m.post("conversations", ":id", "leave", use: leaveGroup)
        m.get("conversations", ":id", "block-alert-state", use: blockAlertState)
        m.post("conversations", ":id", "block-alert-ack", use: acknowledgeBlockAlert)
        m.get("conversations", ":id", "messages", use: listMessages)
        m.post("conversations", ":id", "messages", use: sendMessage)
        m.delete("conversations", ":id", "messages", use: clearConversation)
        m.delete("conversations", ":id", "messages", ":messageId", use: recallMessage)
        m.post("conversations", ":id", "messages", ":messageId", "reactions", use: reactToMessage)
        m.patch("conversations", ":id", "messages", ":messageId", "meeting-proposal", use: updateMeetingProposal)
        m.post("conversations", ":id", "messages", ":messageId", "meeting-proposal", "cancel", use: cancelMeetingProposal)
        m.post("conversations", ":id", "messages", ":messageId", "meeting-response", use: respondToMeeting)
        m.put("conversations", ":id", "read", use: markRead)
        m.put("conversations", ":id", "delivered", use: markDelivered)
        m.get("unread", use: unreadCount)
        m.get("search", use: searchAll)
    }

    static func requireParticipant(_ conversationID: String, _ req: Request) async throws {
        guard try await ChatStore.isParticipant(conversationID, req.userID, on: req.db.sql()) else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
    }

    /// Owner-only gate for group management (participant already verified by
    /// the caller). Mirrors `messageService.requireGroupOwner`.
    static func requireGroupOwner(_ conversationID: String, _ userID: String, on db: any SQLDatabase) async throws {
        guard let conv = try await ChatStore.conversationByID(conversationID, on: db), conv.is_group else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
        guard let role = try await ChatStore.participantRole(conversationID, userID, on: db) else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
        guard role == "owner" else { throw Abort(.forbidden, reason: "Only the group owner can do this") }
    }

    /// 1:1 block guard — no-op for groups (>2 participants). Mirrors
    /// `messageService.assertNotBlockedInConversation`.
    static func assertNotBlockedInConversation(_ conversationID: String, _ userID: String, on db: any SQLDatabase) async throws {
        let parts = try await ChatStore.participants(conversationID, on: db)
        if parts.count > 2 { return }
        if let other = parts.first(where: { $0 != userID }),
           try await UserStore.isBlockedEitherWay(userID, other, on: db) {
            throw Abort(.forbidden, reason: "Cannot message this user")
        }
    }

    /// Resolve a `:messageId` to its active-or-cancelled meeting proposal in
    /// this conversation, 404ing otherwise. Mirrors `resolveMeetingProposal`.
    static func resolveMeetingProposal(_ conversationID: String, _ messageID: String, on db: any SQLDatabase) async throws -> ChatStore.ProposalRow {
        guard let p = try await ChatStore.proposalByMessageID(messageID, on: db),
              p.conversation_id == conversationID, p.message_type == "meeting", p.id != nil else {
            throw Abort(.notFound, reason: "Meeting proposal not found")
        }
        return p
    }

    // MARK: meeting-proposal validation (messageService.validateMeetingProposal)

    static let allowedReminderOffsets = ["on_day", "1_day_before", "2_days_before", "1_week_before"]
    static let reminderOffsetDays: [String: Int] = ["on_day": 0, "1_day_before": 1, "2_days_before": 2, "1_week_before": 7]

    private static let isoIn: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        return [a, b]
    }()
    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    static func parseDate(_ s: String) -> Date? {
        for p in isoIn { if let d = p.date(from: s) { return d } }
        return nil
    }

    static func defaultReminderAt(start: Date, offset: String) -> String {
        let days = reminderOffsetDays[offset] ?? reminderOffsetDays["1_day_before"]!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let shifted = cal.date(byAdding: .day, value: -days, to: start) ?? start
        let ymd = cal.dateComponents([.year, .month, .day], from: shifted)
        let atSeven = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"),
                                                    year: ymd.year, month: ymd.month, day: ymd.day,
                                                    hour: 7, minute: 0, second: 0)) ?? shifted
        return isoOut.string(from: atSeven)
    }

    static func validateMeetingProposal(title: String?, location: String?, startsAt: String?, endsAt: String?,
                                        reminderOffset: String?, reminderAt: String?) throws -> ValidatedMeeting {
        guard let cleanTitle = title?.trimmingCharacters(in: .whitespaces), !cleanTitle.isEmpty else {
            throw Abort(.badRequest, reason: "Meeting title is required")
        }
        guard let startsAtStr = startsAt, !startsAtStr.isEmpty else {
            throw Abort(.badRequest, reason: "Meeting start time is required")
        }
        guard let start = parseDate(startsAtStr) else { throw Abort(.badRequest, reason: "Invalid meeting start time") }
        if start <= Date() { throw Abort(.badRequest, reason: "Meeting start time must be in the future") }

        if let endsAtStr = endsAt, !endsAtStr.isEmpty {
            guard let end = parseDate(endsAtStr) else { throw Abort(.badRequest, reason: "Invalid meeting end time") }
            if end <= start { throw Abort(.badRequest, reason: "Meeting end time must be after the start time") }
        }

        var offset = "1_day_before"
        if let ro = reminderOffset {
            guard allowedReminderOffsets.contains(ro) else { throw Abort(.badRequest, reason: "Invalid reminder offset") }
            offset = ro
        }

        let reminderAtOut: String
        if let ra = reminderAt, !ra.isEmpty {
            guard let parsed = parseDate(ra) else { throw Abort(.badRequest, reason: "Invalid reminder time") }
            reminderAtOut = isoOut.string(from: parsed)
        } else {
            reminderAtOut = defaultReminderAt(start: start, offset: offset)
        }

        return ValidatedMeeting(
            title: cleanTitle,
            location: location?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            startsAt: startsAtStr,
            endsAt: (endsAt?.isEmpty ?? true) ? nil : endsAt,
            reminderOffset: offset,
            reminderAt: reminderAtOut)
    }

    // MARK: upload

    struct UploadResult: Content { var data: Inner; struct Inner: Content { var url: String; var message_type: String } }
    static let uploadDir = "../backend/uploads/messages"
    /// Allowed chat attachments, keyed on the filename extension — because that
    /// is all Vapor's `File` exposes: `File.contentType` is derived from the
    /// extension, not the part's Content-Type header, and it maps "m4a" to
    /// audio/mpeg. Matching on that MIME silently rejected every voice note
    /// (and iPhone HEIC photos) after the port from Node, whose multer trusted
    /// the header. The stored extension still comes from this closed table,
    /// never verbatim from the client.
    static let attachmentTypes: [String: (ext: String, messageType: String)] = [
        "jpg": (".jpg", "image"), "jpeg": (".jpg", "image"), "png": (".png", "image"),
        "gif": (".gif", "image"), "webp": (".webp", "image"), "heic": (".heic", "image"),
        "mp4": (".mp4", "video"), "mov": (".mov", "video"),
        "m4a": (".m4a", "voice"),
    ]

    /// The whitelist entry for an uploaded filename, or nil if it isn't allowed.
    static func attachmentType(forFilename filename: String) -> (ext: String, messageType: String)? {
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        return attachmentTypes[filename[filename.index(after: dot)...].lowercased()]
    }

    static func upload(_ req: Request) async throws -> UploadResult {
        struct FileBody: Content { var file: File }
        guard let file = try? req.content.decode(FileBody.self).file,
              let kind = attachmentType(forFilename: file.filename) else {
            throw Abort(.badRequest, reason: "Invalid or missing file")
        }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())\(kind.ext)"
        try FileManager.default.createDirectory(atPath: uploadDir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(file.data, at: "\(uploadDir)/\(name)")
        return UploadResult(data: .init(url: "/uploads/messages/\(name)", message_type: kind.messageType))
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

    struct MeetingProposalIn: Content {
        var title: String?
        var location: String?
        var starts_at: String?
        var ends_at: String?
        var reminder_offset: String?
        var reminder_at: String?
    }
    struct SendBody: Content {
        var content: String?
        var message_type: String?
        var media_url: String?
        var reply_to_message_id: String?
        var meeting_proposal: MeetingProposalIn?
        var voice_duration_seconds: Int?
        var voice_waveform: [Double]?
    }
    static func sendMessage(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let b = try req.content.decode(SendBody.self)
        let type = b.message_type ?? "text"
        if type == "text", (b.content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
            throw Abort(.badRequest, reason: "Message content is required")
        }
        if ["image", "video", "voice"].contains(type), b.media_url == nil {
            throw Abort(.badRequest, reason: "Media URL is required")
        }
        if let c = b.content, c.count > 2000 { throw Abort(.badRequest, reason: "Message is too long") }

        var validated: ValidatedMeeting? = nil
        if type == "meeting" {
            validated = try validateMeetingProposal(
                title: b.meeting_proposal?.title, location: b.meeting_proposal?.location,
                startsAt: b.meeting_proposal?.starts_at, endsAt: b.meeting_proposal?.ends_at,
                reminderOffset: b.meeting_proposal?.reminder_offset, reminderAt: b.meeting_proposal?.reminder_at)
        }

        var replyTo: String? = nil
        if let rid = b.reply_to_message_id {
            guard let target = try await ChatStore.messageBasic(rid, on: db), target.conversation_id == id else {
                throw Abort(.badRequest, reason: "Message being replied to was not found in this conversation")
            }
            replyTo = rid
        }
        try await assertNotBlockedInConversation(id, req.userID, on: db)

        let storedContent = b.content?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? validated?.title
        let newID = try await ChatStore.insertMessage(id, senderID: req.userID,
            content: storedContent, messageType: type,
            mediaUrl: b.media_url, replyToMessageID: replyTo,
            voiceDuration: b.voice_duration_seconds, voiceWaveform: b.voice_waveform, on: db)
        if let v = validated {
            try await ChatStore.createMeetingProposalRow(messageID: newID, v, on: db)
        }
        guard let msg = try await ChatStore.messageByID(newID, on: db) else { throw Abort(.internalServerError) }
        let parts = try await ChatStore.participants(id, on: db)
        req.socketHub.emitConversation(id, participants: parts, event: "new_message", msg)
        let uid = req.userID
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.notifyNewMessage(conversationID: id, senderID: uid, message: msg, on: d, hub: h, logger: l)
        }
        return try await ConnectionsController.encode(DataResponse(data: msg), req, .created)
    }

    struct StatusOK: Content { var status = "ok" }

    static func recallMessage(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        _ = try await ChatStore.recall(mid, conversationID: id, senderID: req.userID, on: db)
        let parts = try await ChatStore.participants(id, on: db)
        req.socketHub.emitConversation(id, participants: parts, event: "message_deleted",
            WSMessageDeleted(conversation_id: id, message_id: mid))
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
        req.socketHub.emitConversation(id, participants: parts, event: "reaction_updated",
            WSReactionUpdated(conversation_id: id, message_id: mid, reactions: reactions))
        let uid = req.userID, senderID = target.sender_id
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.pushChatNotification(conversationID: id, type: "message_reaction", actorID: uid,
                userIDs: [senderID], entityID: mid, payload: ["messageId": mid, "emoji": emoji], on: d, hub: h, logger: l)
        }
        return ReactionsResponse(data: .init(reactions: reactions))
    }

    static func markRead(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        _ = try await ChatStore.markRead(id, userID: req.userID, on: req.db.sql())
        // Folded review fix: the REST read path also emits messages_read (Node's
        // only fires it from the socket handler) so the other side's ticks
        // update even when the reader used REST.
        req.socketHub.emit(room: id, event: "messages_read", WSMessagesRead(conversationId: id, readBy: req.userID))
        let uid = req.userID
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.clearConversationNotification(conversationID: id, userID: uid, on: d, hub: h, logger: l)
        }
        return StatusOK()
    }

    static func markDelivered(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        try await requireParticipant(id, req)
        let rows = try await ChatStore.markConversationDelivered(id, userID: req.userID, on: req.db.sql())
        // Node's REST catch-up path emits { conversationId, messageId } (no userId).
        for r in rows {
            req.socketHub.emitToUser(r.sender_id, event: "message_delivered",
                WSMessageDelivered(conversationId: id, messageId: r.id, userId: nil))
        }
        return StatusOK()
    }

    struct CountData: Content { var data: Inner; struct Inner: Content { var count: Int } }
    static func unreadCount(_ req: Request) async throws -> CountData {
        guard let mode = try? req.query.get(String.self, at: "mode") else { throw Abort(.badRequest, reason: "mode is required") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }
        return CountData(data: .init(count: try await ChatStore.totalUnread(req.userID, mode: mode, on: req.db.sql())))
    }

    /// Cross-conversation search — conversation name AND message content, so
    /// a user who remembers what they said but not which chat it was in can
    /// find it. Scoped to conversations the requester actually participates
    /// in (see `ChatStore.searchAllConversations`), same mode-scoping as
    /// every other conversation-listing endpoint.
    static func searchAll(_ req: Request) async throws -> DataListResponse<ChatStore.ConversationSearchHit> {
        guard let mode = try? req.query.get(String.self, at: "mode") else { throw Abort(.badRequest, reason: "mode is required") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }
        let term = ((try? req.query.get(String.self, at: "q")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return DataListResponse(data: []) }
        return DataListResponse(data: try await ChatStore.searchAllConversations(req.userID, mode: mode, term: term, on: req.db.sql()))
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
            guard let s = try await ChatStore.groupSettings(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
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
        let pins = try await ChatStore.listPins(id, on: db)
        let parts = try await ChatStore.participants(id, on: db)
        req.socketHub.emitConversation(id, participants: parts, event: "pin_added",
            WSPinAdded(conversation_id: id, message_id: mid, pins: pins))
        return try await ConnectionsController.encode(DataResponse(data: pin), req, .created)
    }
    struct UnpinData: Content { var data: Inner; struct Inner: Content { var unpinned = true } }
    static func unpinMessage(_ req: Request) async throws -> UnpinData {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard try await ChatStore.unpinMessage(id, messageID: mid, on: db) else {
            throw Abort(.notFound, reason: "Pin not found")
        }
        let parts = try await ChatStore.participants(id, on: db)
        req.socketHub.emitConversation(id, participants: parts, event: "pin_removed",
            WSPinRemoved(conversation_id: id, message_id: mid))
        return UnpinData(data: .init())
    }

    // MARK: block-alert (group-only; 1:1 → { shouldAlert: false })

    /// `blockedUserIds` is a plain Optional (omitted when nil) — Node only
    /// includes the key on the `shouldAlert: true` branch.
    struct BlockAlertData: Content { var data: Inner; struct Inner: Content { var shouldAlert = false; var blockedUserIds: [String]? } }
    static func blockAlertState(_ req: Request) async throws -> BlockAlertData {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let conv = try await ChatStore.conversationByID(id, on: db), conv.is_group else {
            return BlockAlertData(data: .init())
        }
        let blocked = try await ChatStore.blockedIDsInConversation(id, userID: req.userID, on: db)
        if blocked.isEmpty { return BlockAlertData(data: .init()) }
        let snapshot = blocked.sorted().joined(separator: ",")
        let ack = try await ChatStore.getBlockAck(id, userID: req.userID, on: db)
        if ack == nil || ack!.acked_blocked_ids != snapshot {
            return BlockAlertData(data: .init(shouldAlert: true, blockedUserIds: blocked))
        }
        return BlockAlertData(data: .init())
    }

    struct AckedData: Content { var data: Inner; struct Inner: Content { var acked = true } }
    static func acknowledgeBlockAlert(_ req: Request) async throws -> AckedData {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let blocked = try await ChatStore.blockedIDsInConversation(id, userID: req.userID, on: db)
        try await ChatStore.setBlockAck(id, userID: req.userID, blockedIDs: blocked, on: db)
        return AckedData(data: .init())
    }

    // MARK: group conversations

    struct GroupCreateBody: Content { var member_ids: [String]?; var mode: String?; var name: String? }
    static func createGroupConversation(_ req: Request) async throws -> Response {
        let b = try req.content.decode(GroupCreateBody.self)
        guard let memberIDs = b.member_ids, !memberIDs.isEmpty else {
            throw Abort(.badRequest, reason: "member_ids is required")
        }
        guard let mode = b.mode else { throw Abort(.badRequest, reason: "mode is required") }
        guard ["hobby", "work"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid mode") }

        var seen = Set<String>(); var unique: [String] = []
        for x in memberIDs where seen.insert(x).inserted { unique.append(x) }
        if unique.count != memberIDs.count { throw Abort(.badRequest, reason: "Duplicate member ids are not allowed") }
        if unique.contains(req.userID) { throw Abort(.badRequest, reason: "Creator should not be listed in member_ids") }
        if unique.count + 1 > 100 { throw Abort(.badRequest, reason: "A group cannot have more than 100 members") }

        var groupName = "New group"
        if let n = b.name {
            let trimmed = n.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { groupName = String(trimmed.prefix(100)) }
        }

        let conv = try await ChatStore.createGroupConversation(
            creatorID: req.userID, memberIDs: unique, mode: mode, name: groupName, on: req.db)
        return try await ConnectionsController.encode(DataResponse(data: conv), req, .created)
    }

    struct SettingsPatchBody: Content { var theme: String?; var nickname: String?; var target_user_id: String? }
    static func updateSettings(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let conv = try await ChatStore.conversationByID(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
        let raw = try req.content.decode(SettingsPatchBody.self)
        let present: Set<String> = {
            guard let dict = try? req.content.decode([String: AnyCodableValue].self) else { return [] }
            return Set(dict.keys)
        }()
        let parts = try await ChatStore.participants(id, on: db)

        if present.contains("theme") {
            if let t = raw.theme, t.count > 20 { throw Abort(.badRequest, reason: "Invalid theme") }
            let value = (raw.theme?.isEmpty ?? true) ? nil : raw.theme
            try await ChatStore.updateTheme(id, theme: value, on: db)
        }

        if present.contains("nickname") {
            var value: String? = nil
            if let nn = raw.nickname {
                let t = String(nn.trimmingCharacters(in: .whitespaces).prefix(50))
                value = t.isEmpty ? nil : t
            }
            if conv.is_group {
                guard let target = raw.target_user_id else {
                    throw Abort(.badRequest, reason: "target_user_id is required to set a nickname in a group")
                }
                guard parts.contains(target) else { throw Abort(.notFound, reason: "User is not a member of this group") }
                if let v = value {
                    try await ChatStore.setGroupNickname(id, setterID: req.userID, targetID: target, nickname: v, on: db)
                } else {
                    try await ChatStore.deleteGroupNickname(id, setterID: req.userID, targetID: target, on: db)
                }
            } else if let other = parts.first(where: { $0 != req.userID }) {
                try await ChatStore.setNickname(id, targetUserID: other, nickname: value, on: db)
            }
        }

        if conv.is_group {
            guard let s = try await ChatStore.groupSettings(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
            let payload = WSGroupSettingsUpdated(conversation_id: id, theme: s.theme)
            for uid in parts { req.socketHub.emitToUser(uid, event: "conversation_settings_updated", payload) }
            return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
        } else {
            guard let s = try await ChatStore.settings1to1(id, userID: req.userID, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
            let payload = WSDirectSettingsUpdated(conversation_id: id, theme: s.theme,
                nickname_target_id: s.other_user_id, nickname: s.other_user_nickname)
            for uid in parts { req.socketHub.emitToUser(uid, event: "conversation_settings_updated", payload) }
            return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
        }
    }

    struct MemberIDsBody: Content { var member_ids: [String]? }
    static func addMembers(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let ids = try req.content.decode(MemberIDsBody.self).member_ids, !ids.isEmpty else {
            throw Abort(.badRequest, reason: "member_ids is required")
        }
        try await requireGroupOwner(id, req.userID, on: db)

        var seen = Set<String>(); var uniqueNew: [String] = []
        for x in ids where seen.insert(x).inserted { uniqueNew.append(x) }
        let current = try await ChatStore.participants(id, on: db)
        let currentSet = Set(current)
        let toAdd = uniqueNew.filter { !currentSet.contains($0) }
        if !toAdd.isEmpty, current.count + toAdd.count > 100 {
            throw Abort(.badRequest, reason: "A group cannot have more than 100 members")
        }
        if !toAdd.isEmpty { try await ChatStore.addParticipants(id, toAdd, on: db) }
        guard let s = try await ChatStore.groupSettings(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
        let after = try await ChatStore.participants(id, on: db)
        req.socketHub.emitConversation(id, participants: after, event: "member_added",
            WSMemberAdded(conversation_id: id, added_user_ids: toAdd, members: s.members))
        if !toAdd.isEmpty {
            let uid = req.userID, added = toAdd
            NotifyService.fireAndForget(req) { d, h, l in
                await NotifyService.pushChatNotification(conversationID: id, type: "group_added", actorID: uid,
                    userIDs: added, on: d, hub: h, logger: l)
            }
        }
        return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
    }

    struct RemovedData: Content { var data: Inner; struct Inner: Content { var removed = true } }
    static func removeMember(_ req: Request) async throws -> RemovedData {
        let id = req.parameters.get("id")!, target = req.parameters.get("userId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        try await requireGroupOwner(id, req.userID, on: db)
        if target == req.userID { throw Abort(.badRequest, reason: "Use leave instead of removing yourself") }
        guard try await ChatStore.isParticipant(id, target, on: db) else {
            throw Abort(.notFound, reason: "User is not a member of this group")
        }
        try await ChatStore.removeParticipant(id, target, on: db)
        let payload = WSMemberRemoved(conversation_id: id, removed_user_id: target)
        for uid in try await ChatStore.participants(id, on: db) {
            req.socketHub.emitToUser(uid, event: "member_removed", payload)
        }
        req.socketHub.emitToUser(target, event: "removed_from_conversation", payload)
        let uid = req.userID, tgt = target
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.pushChatNotification(conversationID: id, type: "group_removed", actorID: uid,
                userIDs: [tgt], on: d, hub: h, logger: l)
        }
        return RemovedData(data: .init())
    }

    static func promoteOwner(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!, target = req.parameters.get("userId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        try await requireGroupOwner(id, req.userID, on: db)
        if target == req.userID { throw Abort(.badRequest, reason: "You are already the owner") }
        guard try await ChatStore.isParticipant(id, target, on: db) else {
            throw Abort(.notFound, reason: "User is not a member of this group")
        }
        try await ChatStore.transferOwnership(id, from: req.userID, to: target, on: req.db)
        guard let s = try await ChatStore.groupSettings(id, on: db) else { throw Abort(.notFound, reason: "Conversation not found") }
        try await broadcastGroupUpdated(req, id, settings: s, newOwnerID: target)
        return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
    }

    /// `broadcastGroupUpdated` — `group_updated` to the room + every participant.
    static func broadcastGroupUpdated(_ req: Request, _ conversationID: String,
                                     settings s: ChatStore.GroupSettings, newOwnerID: String? = nil) async throws {
        let payload = WSGroupUpdated(conversation_id: conversationID, name: s.name,
            avatar_url: s.avatar_url, avatar_color: s.avatar_color, new_owner_id: newOwnerID)
        let parts = try await ChatStore.participants(conversationID, on: req.db.sql())
        req.socketHub.emitConversation(conversationID, participants: parts, event: "group_updated", payload)
    }

    struct GroupPatchBody: Content { var name: String?; var avatar_url: String?; var avatar_color: String? }
    static func updateGroup(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let raw = try req.content.decode(GroupPatchBody.self)
        let present: Set<String> = {
            guard let dict = try? req.content.decode([String: AnyCodableValue].self) else { return [] }
            return Set(dict.keys)
        }()

        var settings: ChatStore.GroupSettings? = nil
        if present.contains("name") {
            try await requireGroupOwner(id, req.userID, on: db)
            guard let n = raw.name, !n.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Abort(.badRequest, reason: "Group name is required")
            }
            try await ChatStore.updateGroupInfo(id, sets: [("name", String(n.trimmingCharacters(in: .whitespaces).prefix(100)))], on: db)
            settings = try await ChatStore.groupSettings(id, on: db)
        }
        if present.contains("avatar_url") || present.contains("avatar_color") {
            try await requireGroupOwner(id, req.userID, on: db)
            var sets: [(String, String?)] = []
            if present.contains("avatar_url") { sets.append(("avatar_url", raw.avatar_url)) }
            if present.contains("avatar_color") { sets.append(("avatar_color", raw.avatar_color)) }
            try await ChatStore.updateGroupInfo(id, sets: sets, on: db)
            settings = try await ChatStore.groupSettings(id, on: db)
        }
        guard let s = settings else {
            throw Abort(.badRequest, reason: "name, avatar_url or avatar_color is required")
        }
        try await broadcastGroupUpdated(req, id, settings: s)
        return try await ConnectionsController.encode(SettingsData(data: s), req, .ok)
    }

    static func leaveGroup(_ req: Request) async throws -> StatusOK {
        let id = req.parameters.get("id")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let conv = try await ChatStore.conversationByID(id, on: db), conv.is_group else {
            throw Abort(.notFound, reason: "Conversation not found")
        }
        let role = try await ChatStore.participantRole(id, req.userID, on: db)
        let ordered = try await ChatStore.participantsByJoin(id, on: db)
        let others = ordered.filter { $0 != req.userID }
        if role == "owner", let heir = others.first {
            try await ChatStore.transferOwnership(id, from: req.userID, to: heir, on: req.db)
        }
        try await ChatStore.removeParticipant(id, req.userID, on: db)
        let payload = WSMemberRemoved(conversation_id: id, removed_user_id: req.userID)
        for uid in try await ChatStore.participants(id, on: db) {
            req.socketHub.emitToUser(uid, event: "member_removed", payload)
        }
        return StatusOK()
    }

    // MARK: meeting-proposal mutation

    static func updateMeetingProposal(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let p = try await resolveMeetingProposal(id, mid, on: db)
        guard req.userID == p.sender_id else { throw Abort(.forbidden, reason: "Only the proposer can reschedule this meeting") }
        guard p.status == "active" else { throw Abort(.conflict, reason: "Cannot reschedule a cancelled meeting") }
        try await assertNotBlockedInConversation(id, req.userID, on: db)

        let b = try req.content.decode(MeetingProposalIn.self)
        let v = try validateMeetingProposal(
            title: b.title, location: b.location, startsAt: b.starts_at, endsAt: b.ends_at,
            reminderOffset: b.reminder_offset, reminderAt: b.reminder_at)
        try await ChatStore.updateMeetingProposalRow(p.id!, v, on: req.db)

        guard let msg = try await ChatStore.messageByID(mid, on: db), let mp = msg.meeting_proposal else {
            throw Abort(.internalServerError)
        }
        try await emitMeeting(req, id, mid, event: "meeting_proposal_updated", proposal: mp)
        let uid = req.userID, pid = p.id!, ttl = v.title, sa = v.startsAt
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.pushChatNotification(conversationID: id, type: "meeting_updated", actorID: uid,
                entityID: pid, payload: ["messageId": mid, "proposalId": pid, "changeKind": "rescheduled",
                                         "title": ttl, "startsAt": sa], on: d, hub: h, logger: l)
        }
        return try await ConnectionsController.encode(DataResponse(data: mp), req, .ok)
    }

    /// Fan `meeting_proposal_updated` / `meeting_response_updated` to the room +
    /// every participant, payload `{ conversation_id, message_id, meeting_proposal }`.
    static func emitMeeting(_ req: Request, _ conversationID: String, _ messageID: String,
                            event: String, proposal: MessageObject.MeetingProposal) async throws {
        let parts = try await ChatStore.participants(conversationID, on: req.db.sql())
        req.socketHub.emitConversation(conversationID, participants: parts, event: event,
            WSMeetingProposal(conversation_id: conversationID, message_id: messageID, meeting_proposal: proposal))
    }

    static func cancelMeetingProposal(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        let p = try await resolveMeetingProposal(id, mid, on: db)
        guard req.userID == p.sender_id else { throw Abort(.forbidden, reason: "Only the proposer can cancel this meeting") }
        guard p.status == "active" else { throw Abort(.conflict, reason: "Meeting is already cancelled") }
        try await assertNotBlockedInConversation(id, req.userID, on: db)

        try await ChatStore.cancelMeetingProposalRow(p.id!, on: db)
        guard let msg = try await ChatStore.messageByID(mid, on: db), let mp = msg.meeting_proposal else {
            throw Abort(.internalServerError)
        }
        try await emitMeeting(req, id, mid, event: "meeting_proposal_updated", proposal: mp)
        let uid = req.userID, pid = p.id!, ttl = mp.title
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.pushChatNotification(conversationID: id, type: "meeting_updated", actorID: uid,
                entityID: pid, payload: ["messageId": mid, "proposalId": pid, "changeKind": "cancelled",
                                         "title": ttl], on: d, hub: h, logger: l)
        }
        return try await ConnectionsController.encode(DataResponse(data: mp), req, .ok)
    }

    struct RsvpBody: Content { var status: String? }
    static let allowedRsvp = ["going", "maybe", "not_going"]
    static func respondToMeeting(_ req: Request) async throws -> Response {
        let id = req.parameters.get("id")!, mid = req.parameters.get("messageId")!
        let db = req.db.sql()
        try await requireParticipant(id, req)
        guard let status = try req.content.decode(RsvpBody.self).status else {
            throw Abort(.badRequest, reason: "status is required")
        }
        guard allowedRsvp.contains(status) else {
            throw Abort(.badRequest, reason: "Status must be going, maybe, or not_going")
        }
        let p = try await resolveMeetingProposal(id, mid, on: db)
        guard let conv = try await ChatStore.conversationByID(id, on: db), conv.is_group else {
            throw Abort(.badRequest, reason: "RSVP is not applicable to a 1:1 meeting")
        }
        try await assertNotBlockedInConversation(id, req.userID, on: db)
        guard try await ChatStore.setMeetingRsvp(p.id!, userID: req.userID, status: status, on: db) else {
            throw Abort(.conflict, reason: "Cannot respond to a cancelled meeting")
        }
        guard let msg = try await ChatStore.messageByID(mid, on: db), let mp = msg.meeting_proposal else {
            throw Abort(.internalServerError)
        }
        try await emitMeeting(req, id, mid, event: "meeting_response_updated", proposal: mp)
        let uid = req.userID, pid = p.id!, proposer = p.sender_id, st = status
        NotifyService.fireAndForget(req) { d, h, l in
            await NotifyService.pushChatNotification(conversationID: id, type: "meeting_rsvp", actorID: uid,
                userIDs: [proposer], entityID: pid,
                payload: ["messageId": mid, "proposalId": pid, "status": st], on: d, hub: h, logger: l)
        }
        return try await ConnectionsController.encode(DataResponse(data: mp), req, .ok)
    }
}
