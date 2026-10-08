import Vapor
import Foundation
import SQLKit

/// The client→server Socket.IO event handlers, ported 1:1 from the
/// `io.on('connection', …)` block in `backend/index.js`. Payload keys are
/// **camelCase** in (matching the client) and the exact casing Node emits out.
/// Error strings are copied verbatim — the socket path uses its own literals
/// (e.g. `Not a participant`), not the REST `Abort` reasons.
enum SocketHandlers {

    // MARK: dispatch

    static func dispatch(event: String, arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        switch event {
        case "get_presence":          await sendPresenceSnapshot(session: session)
        case "join_conversation":     await joinConversation(arg, conn: conn, session: session)
        case "leave_conversation":    await leaveConversation(arg, conn: conn, session: session)
        case "join_community":        await joinCommunity(arg, ackID: ackID, conn: conn, session: session)
        case "leave_community":       await leaveCommunity(arg, ackID: ackID, conn: conn, session: session)
        case "send_message":          await sendMessage(arg, ackID: ackID, conn: conn, session: session)
        case "react_message":         await reactMessage(arg, ackID: ackID, conn: conn, session: session)
        case "update_meeting_proposal": await updateMeeting(arg, ackID: ackID, conn: conn, session: session)
        case "cancel_meeting_proposal": await cancelMeeting(arg, ackID: ackID, conn: conn, session: session)
        case "respond_meeting":       await respondMeeting(arg, ackID: ackID, conn: conn, session: session)
        case "mark_read":             await markRead(arg, ackID: ackID, conn: conn, session: session)
        case "message_delivered":     await messageDelivered(arg, ackID: ackID, conn: conn, session: session)
        case "pin_message":           await pinMessage(arg, ackID: ackID, conn: conn, session: session)
        case "unpin_message":         await unpinMessage(arg, ackID: ackID, conn: conn, session: session)
        case "typing":                await typing(arg, conn: conn, session: session)
        default:                      break
        }
    }

    // MARK: helpers

    private static func decode<T: Decodable>(_ arg: Any?, _ type: T.Type) -> T? {
        guard let arg, let data = try? JSONSerialization.data(withJSONObject: arg) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    /// `Abort` → its `reason` (the shared validators throw `Abort`; the socket
    /// path surfaces the message string directly).
    private static func reason(_ error: any Error) -> String {
        (error as? AbortError)?.reason ?? "\(error)"
    }
    private struct AckData<T: Encodable>: Encodable { let data: T }
    private static func ackData<T: Encodable>(_ session: SocketSession, _ ackID: Int?, _ value: T) async {
        await session.ack(ackID, SocketJSON.data(AckData(data: value)))
    }

    // MARK: presence

    static func acceptedConnectionIDs(_ userID: String, on db: any SQLDatabase) async throws -> [String] {
        struct R: Decodable { let other_id: String }
        return try await db.raw("""
            SELECT (CASE WHEN requester_id = \(uuid: userID) THEN addressee_id ELSE requester_id END)::text AS other_id
            FROM connections
            WHERE status = 'accepted' AND (requester_id = \(uuid: userID) OR addressee_id = \(uuid: userID))
            """).all(decoding: R.self).map(\.other_id)
    }

    static func broadcastPresence(_ userID: String, online: Bool, session: SocketSession) async {
        do {
            let ids = try await acceptedConnectionIDs(userID, on: session.db.sql())
            let payload = WSPresenceUpdate(userId: userID, online: online)
            for cid in ids { session.hub.emitToUser(cid, event: "presence_update", payload) }
        } catch {
            session.logger.warning("broadcastPresence failed: \(error)")
        }
    }

    static func sendPresenceSnapshot(session: SocketSession) async {
        guard let userID = await session.conn?.userID else { return }
        do {
            let ids = try await acceptedConnectionIDs(userID, on: session.db.sql())
            let onlineIDs = ids.filter { session.hub.isOnline($0) }
            await session.emitSelf(event: "presence_snapshot", SocketJSON.data(WSPresenceSnapshot(userIds: onlineIDs)))
        } catch {
            session.logger.warning("sendPresenceSnapshot failed: \(error)")
        }
    }

    // MARK: rooms

    private static func joinConversation(_ arg: Any?, conn: SocketConn, session: SocketSession) async {
        guard let cid = arg as? String else { return }
        let allowed = (try? await ChatStore.isParticipant(cid, conn.userID, on: session.db.sql())) ?? false
        if allowed { session.hub.join(conn, cid) }
    }
    private static func leaveConversation(_ arg: Any?, conn: SocketConn, session: SocketSession) async {
        guard let cid = arg as? String else { return }
        session.hub.leave(conn, cid)
    }
    private static func joinCommunity(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let id = arg as? String else { await session.ackError(ackID, "Failed to join community"); return }
        do {
            let membership = try await CommunityStore.membership(id, conn.userID, on: session.db.sql())
            guard membership != nil else { await session.ackError(ackID, "Not a member of this community"); return }
            session.hub.join(conn, "community:\(id)")
            await ackData(session, ackID, ["joined": true])
        } catch {
            session.logger.error("join_community error: \(error)")
            await session.ackError(ackID, "Failed to join community")
        }
    }
    private static func leaveCommunity(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        if let id = arg as? String { session.hub.leave(conn, "community:\(id)") }
        await ackData(session, ackID, ["left": true])
    }

    // MARK: send_message

    private struct MeetingArg: Decodable {
        var title: String?; var location: String?; var startsAt: String?; var endsAt: String?
        var reminderOffset: String?; var reminderAt: String?
    }
    private struct SendArg: Decodable {
        var conversationId: String?; var content: String?; var messageType: String?
        var mediaUrl: String?; var mediaItems: [MessageObject.MediaItem]?
        var replyToMessageId: String?; var meetingProposal: MeetingArg?
        var voiceDurationSeconds: Int?; var voiceWaveform: [Double]?
    }
    private static func sendMessage(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, SendArg.self), let cid = b.conversationId else {
            await session.ackError(ackID, "Failed to send message"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            let type = b.messageType ?? "text"
            if type == "text", (b.content?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                await session.ackError(ackID, "Content required"); return
            }
            if let c = b.content, c.count > 2000 { await session.ackError(ackID, "Message is too long"); return }
            let album: [MessageObject.MediaItem]?
            do { album = try MessagesController.validateAlbum(type: type, items: b.mediaItems) }
            catch { await session.ackError(ackID, reason(error)); return }
            var validated: ValidatedMeeting? = nil
            if type == "meeting" {
                do {
                    validated = try MessagesController.validateMeetingProposal(
                        title: b.meetingProposal?.title, location: b.meetingProposal?.location,
                        startsAt: b.meetingProposal?.startsAt, endsAt: b.meetingProposal?.endsAt,
                        reminderOffset: b.meetingProposal?.reminderOffset, reminderAt: b.meetingProposal?.reminderAt)
                } catch { await session.ackError(ackID, reason(error)); return }
            }
            var replyTo: String? = nil
            if let rid = b.replyToMessageId, let t = try await ChatStore.messageBasic(rid, on: db), t.conversation_id == cid {
                replyTo = rid
            }
            do {
                try await MessagesController.assertNotBlockedInConversation(cid, conn.userID, on: db)
            } catch { await session.ackError(ackID, "Cannot message this user"); return }
            if try await MessageRequests.gate(conversationID: cid, senderID: conn.userID, on: db) == .limitReached {
                await session.ackError(ackID, MessageRequests.limitReason); return
            }

            let stored = b.content?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? validated?.title
            let newID = try await ChatStore.insertMessage(cid, senderID: conn.userID, content: stored, messageType: type,
                mediaUrl: album?.first?.url ?? b.mediaUrl, mediaItems: album, replyToMessageID: replyTo,
                voiceDuration: b.voiceDurationSeconds, voiceWaveform: b.voiceWaveform, on: db)
            if let v = validated { try await ChatStore.createMeetingProposalRow(messageID: newID, v, on: db) }
            guard let msg = try await ChatStore.messageByID(newID, on: db) else {
                await session.ackError(ackID, "Failed to send message"); return
            }
            let parts = try await ChatStore.participants(cid, on: db)
            session.hub.emitConversation(cid, participants: parts, event: "new_message", msg)
            Task { await NotifyService.notifyNewMessage(conversationID: cid, senderID: conn.userID, message: msg,
                on: session.db.sql(), hub: session.hub, logger: session.logger) }
            await ackData(session, ackID, msg)
        } catch {
            session.logger.error("send_message error: \(error)")
            await session.ackError(ackID, "Failed to send message")
        }
    }

    // MARK: react_message

    private struct ReactArg: Decodable { var conversationId: String?; var messageId: String?; var emoji: String? }
    private static func reactMessage(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, ReactArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to react to message"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            guard let emoji = b.emoji, ChatStore.reactionEmoji.contains(emoji) else {
                await session.ackError(ackID, "Unsupported emoji"); return
            }
            guard let t = try await ChatStore.messageBasic(mid, on: db), t.conversation_id == cid else {
                await session.ackError(ackID, "Message not found"); return
            }
            do { try await MessagesController.assertNotBlockedInConversation(cid, conn.userID, on: db) }
            catch { await session.ackError(ackID, "Cannot message this user"); return }

            let reactions = try await ChatStore.setReaction(mid, userID: conn.userID, emoji: emoji, on: db)
            let parts = try await ChatStore.participants(cid, on: db)
            session.hub.emitConversation(cid, participants: parts, event: "reaction_updated",
                WSReactionUpdated(conversation_id: cid, message_id: mid, reactions: reactions))
            Task { await NotifyService.pushChatNotification(conversationID: cid, type: "message_reaction",
                actorID: conn.userID, userIDs: [t.sender_id], entityID: mid,
                payload: ["messageId": mid, "emoji": emoji], on: session.db.sql(), hub: session.hub, logger: session.logger) }
            await ackData(session, ackID, reactions)
        } catch {
            session.logger.error("react_message error: \(error)")
            await session.ackError(ackID, "Failed to react to message")
        }
    }

    // MARK: meeting proposal mutation

    private struct UpdateMeetingArg: Decodable {
        var conversationId: String?; var messageId: String?
        var title: String?; var location: String?; var startsAt: String?; var endsAt: String?
        var reminderOffset: String?; var reminderAt: String?
    }
    private static func updateMeeting(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, UpdateMeetingArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to reschedule meeting"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            let p: ChatStore.ProposalRow
            do { p = try await MessagesController.resolveMeetingProposal(cid, mid, on: db) }
            catch { await session.ackError(ackID, "Meeting proposal not found"); return }
            guard conn.userID == p.sender_id else { await session.ackError(ackID, "Only the proposer can reschedule this meeting"); return }
            guard p.status == "active" else { await session.ackError(ackID, "Cannot reschedule a cancelled meeting"); return }
            do { try await MessagesController.assertNotBlockedInConversation(cid, conn.userID, on: db) }
            catch { await session.ackError(ackID, "Cannot message this user"); return }

            let v: ValidatedMeeting
            do {
                v = try MessagesController.validateMeetingProposal(
                    title: b.title, location: b.location, startsAt: b.startsAt, endsAt: b.endsAt,
                    reminderOffset: b.reminderOffset, reminderAt: b.reminderAt)
            } catch { await session.ackError(ackID, reason(error)); return }

            try await ChatStore.updateMeetingProposalRow(p.id!, v, on: session.db)
            await emitMeeting(cid: cid, mid: mid, event: "meeting_proposal_updated", ackID: ackID, conn: conn, session: session)
            Task { await NotifyService.pushChatNotification(conversationID: cid, type: "meeting_updated", actorID: conn.userID,
                entityID: p.id!, payload: ["messageId": mid, "proposalId": p.id!, "changeKind": "rescheduled",
                    "title": v.title, "startsAt": v.startsAt], on: session.db.sql(), hub: session.hub, logger: session.logger) }
        } catch {
            session.logger.error("update_meeting_proposal error: \(error)")
            await session.ackError(ackID, "Failed to reschedule meeting")
        }
    }

    private struct CancelMeetingArg: Decodable { var conversationId: String?; var messageId: String? }
    private static func cancelMeeting(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, CancelMeetingArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to cancel meeting"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            let p: ChatStore.ProposalRow
            do { p = try await MessagesController.resolveMeetingProposal(cid, mid, on: db) }
            catch { await session.ackError(ackID, "Meeting proposal not found"); return }
            guard conn.userID == p.sender_id else { await session.ackError(ackID, "Only the proposer can cancel this meeting"); return }
            guard p.status == "active" else { await session.ackError(ackID, "Meeting is already cancelled"); return }
            do { try await MessagesController.assertNotBlockedInConversation(cid, conn.userID, on: db) }
            catch { await session.ackError(ackID, "Cannot message this user"); return }

            try await ChatStore.cancelMeetingProposalRow(p.id!, on: db)
            await emitMeeting(cid: cid, mid: mid, event: "meeting_proposal_updated", ackID: ackID, conn: conn, session: session)
            let msgP = try? await ChatStore.messageByID(mid, on: db)
            Task { await NotifyService.pushChatNotification(conversationID: cid, type: "meeting_updated", actorID: conn.userID,
                entityID: p.id!, payload: ["messageId": mid, "proposalId": p.id!, "changeKind": "cancelled",
                    "title": (msgP?.meeting_proposal?.title as Any?) ?? NSNull()],
                on: session.db.sql(), hub: session.hub, logger: session.logger) }
        } catch {
            session.logger.error("cancel_meeting_proposal error: \(error)")
            await session.ackError(ackID, "Failed to cancel meeting")
        }
    }

    private struct RespondMeetingArg: Decodable { var conversationId: String?; var messageId: String?; var status: String? }
    private static func respondMeeting(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, RespondMeetingArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to respond to meeting"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            guard let status = b.status, MessagesController.allowedRsvp.contains(status) else {
                await session.ackError(ackID, "Status must be going, maybe, or not_going"); return
            }
            let p: ChatStore.ProposalRow
            do { p = try await MessagesController.resolveMeetingProposal(cid, mid, on: db) }
            catch { await session.ackError(ackID, "Meeting proposal not found"); return }
            guard let cv = try await ChatStore.conversationByID(cid, on: db), cv.is_group else {
                await session.ackError(ackID, "RSVP is not applicable to a 1:1 meeting"); return
            }
            do { try await MessagesController.assertNotBlockedInConversation(cid, conn.userID, on: db) }
            catch { await session.ackError(ackID, "Cannot message this user"); return }

            guard try await ChatStore.setMeetingRsvp(p.id!, userID: conn.userID, status: status, on: db) else {
                await session.ackError(ackID, "Cannot respond to a cancelled meeting"); return
            }
            await emitMeeting(cid: cid, mid: mid, event: "meeting_response_updated", ackID: ackID, conn: conn, session: session)
            Task { await NotifyService.pushChatNotification(conversationID: cid, type: "meeting_rsvp", actorID: conn.userID,
                userIDs: [p.sender_id], entityID: p.id!, payload: ["messageId": mid, "proposalId": p.id!, "status": status],
                on: session.db.sql(), hub: session.hub, logger: session.logger) }
        } catch {
            session.logger.error("respond_meeting error: \(error)")
            await session.ackError(ackID, "Failed to respond to meeting")
        }
    }

    /// Shared tail for the three meeting mutations: refetch the message, fan out
    /// the given event, ack `{data: meeting_proposal}`.
    private static func emitMeeting(cid: String, mid: String, event: String, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        let db = session.db.sql()
        do {
            guard let msg = try await ChatStore.messageByID(mid, on: db) else { return }
            let parts = try await ChatStore.participants(cid, on: db)
            session.hub.emitConversation(cid, participants: parts, event: event,
                WSMeetingProposal(conversation_id: cid, message_id: mid, meeting_proposal: msg.meeting_proposal))
            await ackData(session, ackID, msg.meeting_proposal)
        } catch {
            session.logger.error("\(event) emit failed: \(error)")
        }
    }

    // MARK: read / delivered

    private struct MarkReadArg: Decodable { var conversationId: String? }
    private static func markRead(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let cid = decode(arg, MarkReadArg.self)?.conversationId else {
            await session.ackError(ackID, "Failed to mark conversation as read"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            _ = try await ChatStore.markRead(cid, userID: conn.userID, on: db)
            session.hub.emit(room: cid, event: "messages_read",
                WSMessagesRead(conversationId: cid, readBy: conn.userID), except: conn)
            Task { await NotifyService.clearConversationNotification(conversationID: cid, userID: conn.userID,
                on: session.db.sql(), hub: session.hub, logger: session.logger) }
            await ackData(session, ackID, ["status": "ok"])
        } catch {
            session.logger.error("mark_read error: \(error)")
            await session.ackError(ackID, "Failed to mark conversation as read")
        }
    }

    private struct DeliveredArg: Decodable { var conversationId: String?; var messageId: String? }
    private static func messageDelivered(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, DeliveredArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to mark message delivered"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            let updated = try await ChatStore.markMessageDelivered(mid, userID: conn.userID, on: db)
            if let u = updated {
                session.hub.emitToUser(u.sender_id, event: "message_delivered",
                    WSMessageDelivered(conversationId: cid, messageId: mid, userId: conn.userID))
            }
            await ackData(session, ackID, updated)
        } catch {
            session.logger.error("message_delivered error: \(error)")
            await session.ackError(ackID, "Failed to mark message delivered")
        }
    }

    // MARK: pins

    private struct PinArg: Decodable { var conversationId: String?; var messageId: String?; var expiresAt: String? }
    private static func pinMessage(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, PinArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to pin message"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            guard let t = try await ChatStore.messageBasic(mid, on: db), t.conversation_id == cid else {
                await session.ackError(ackID, "Message not found"); return
            }
            var expiresAt: String? = nil
            if let raw = b.expiresAt {
                guard let parsed = MessagesController.parseDate(raw) else {
                    await session.ackError(ackID, "Invalid expires_at"); return
                }
                if parsed <= Date() { await session.ackError(ackID, "expires_at must be in the future"); return }
                expiresAt = raw
            }
            guard let pin = try await ChatStore.pinMessage(cid, messageID: mid, userID: conn.userID, expiresAt: expiresAt, on: db) else {
                await session.ackError(ackID, "This conversation already has \(ChatStore.maxPins) pinned messages"); return
            }
            let pins = try await ChatStore.listPins(cid, on: db)
            let parts = try await ChatStore.participants(cid, on: db)
            session.hub.emitConversation(cid, participants: parts, event: "pin_added",
                WSPinAdded(conversation_id: cid, message_id: mid, pins: pins))
            await ackData(session, ackID, pin)
        } catch {
            session.logger.error("pin_message error: \(error)")
            await session.ackError(ackID, "Failed to pin message")
        }
    }

    private struct UnpinArg: Decodable { var conversationId: String?; var messageId: String? }
    private static func unpinMessage(_ arg: Any?, ackID: Int?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, UnpinArg.self), let cid = b.conversationId, let mid = b.messageId else {
            await session.ackError(ackID, "Failed to unpin message"); return
        }
        let db = session.db.sql()
        do {
            guard try await ChatStore.isParticipant(cid, conn.userID, on: db) else {
                await session.ackError(ackID, "Not a participant"); return
            }
            guard try await ChatStore.unpinMessage(cid, messageID: mid, on: db) else {
                await session.ackError(ackID, "Pin not found"); return
            }
            let parts = try await ChatStore.participants(cid, on: db)
            session.hub.emitConversation(cid, participants: parts, event: "pin_removed",
                WSPinRemoved(conversation_id: cid, message_id: mid))
            await ackData(session, ackID, ["unpinned": true])
        } catch {
            session.logger.error("unpin_message error: \(error)")
            await session.ackError(ackID, "Failed to unpin message")
        }
    }

    // MARK: typing

    private struct TypingArg: Decodable { var conversationId: String?; var isTyping: Bool? }
    private static func typing(_ arg: Any?, conn: SocketConn, session: SocketSession) async {
        guard let b = decode(arg, TypingArg.self), let cid = b.conversationId else { return }
        session.hub.emit(room: cid, event: "user_typing",
            WSUserTyping(userId: conn.userID, isTyping: b.isTyping ?? false), except: conn)
    }
}
