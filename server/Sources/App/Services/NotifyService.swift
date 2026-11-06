import Vapor
import SQLKit

/// Port of `backend/src/services/userNotifyService.js` (write side) +
/// `userNotificationModel.js` inserts. The single funnel for creating a
/// notification: writes the row and pushes `notification` + `notification_count`
/// over the Socket.IO shim so the two can never drift. Every entry point
/// swallows its own errors. A notification must never fail the action that
/// triggered it.
///
/// Reuses `NotificationsController.types` / `.toDTOJSON` / `.summary` (the read
/// side, already ported).
enum NotifyService {
    static let previewLength = 120

    // MARK: row insert (RETURNING the read-side Row shape)

    private static let returningRow: SQLQueryString = """
        RETURNING id::text AS id, user_id::text AS user_id, type, actor_id::text AS actor_id,
          post_id::text AS post_id, community_id::text AS community_id, conversation_id::text AS conversation_id,
          entity_type, entity_id::text AS entity_id,
          COALESCE(group_key, type || ':' || id::text) AS group_key,
          payload::text AS payload, collapse_count, is_read, resolved_at, created_at, updated_at,
          NULL::text AS community_name
        """

    struct Refs { var entityType: String?; var entityID: String?; var groupKey: String }
    static func resolveRefs(type: String, entityType: String?, entityID: String?, groupTargetID: String?,
                            postID: String?, conversationID: String?, communityID: String?) -> Refs {
        let eid = entityID ?? postID ?? conversationID ?? communityID
        return Refs(entityType: entityType ?? defaultEntityType(type),
                    entityID: eid,
                    groupKey: "\(type):\(groupTargetID ?? eid ?? "none")")
    }
    static func defaultEntityType(_ type: String) -> String? {
        switch NotificationsController.types[type]?.category {
        case "social": return ["post_liked": "post", "post_commented": "comment", "comment_replied": "comment",
                               "comment_liked": "comment", "post_shared": "post", "connection_request": "user",
                               "connection_accepted": "user", "birthday": "user", "mode_mismatch": "post",
                               "skill_endorsed": "user", "job_application": "job", "application_status": "job", "new_login": "user"][type]
        case "chat": return ["message": "conversation", "meeting_proposed": "meeting", "meeting_updated": "meeting",
                             "meeting_rsvp": "meeting", "meeting_reminder": "meeting", "message_reaction": "message",
                             "group_added": "conversation", "group_removed": "conversation"][type]
        case "community": return ["new_post": "post", "pinned_post": "post", "post_approved": "post",
                                 "post_declined": "community", "join_request": "join_request",
                                 "join_approved": "join_request", "join_rejected": "join_request",
                                 "role_changed": "community", "new_report": "report", "content_removed": "community"][type]
        default: return nil
        }
    }

    static func emitCounts(_ userID: String, on db: any SQLDatabase, hub: SocketHub) async {
        if let (unread, byCat) = try? await NotificationsController.summary(userID, on: db) {
            hub.emitToUser(userID, event: "notification_count", Counts(unread: unread, byCategory: byCat))
        }
    }
    struct Counts: Content { var unread: Int; var byCategory: [String: Int] }

    // MARK: pushUserNotification

    @discardableResult
    static func pushUserNotification(userID: String, type: String, actorID: String? = nil,
                                     postID: String? = nil, communityID: String? = nil, conversationID: String? = nil,
                                     entityType: String? = nil, entityID: String? = nil, groupTargetID: String? = nil,
                                     payload: [String: Any] = [:], actorMode: String? = nil,
                                     on db: any SQLDatabase, hub: SocketHub, logger: Logger) async -> Bool {
        guard NotificationsController.types[type] != nil else {
            logger.warning("refusing notification of unknown type \(type)"); return false
        }
        do {
            let refs = resolveRefs(type: type, entityType: entityType, entityID: entityID, groupTargetID: groupTargetID,
                                   postID: postID, conversationID: conversationID, communityID: communityID)
            var pl = payload
            if let aid = actorID, pl["fromUserId"] == nil {
                let mode = await NotifyService.actorMode(type: type, given: actorMode, postID: postID, conversationID: conversationID,
                                           communityID: communityID, on: db)
                for (k, v) in try await actorPayload(aid, mode: mode, on: db) { pl[k] = v }
            }
            let plJSON = String(data: (try? JSONSerialization.data(withJSONObject: pl)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            let row = try await db.raw("""
                INSERT INTO user_notifications
                  (user_id, type, actor_id, post_id, community_id, conversation_id, entity_type, entity_id, group_key, payload)
                VALUES (\(uuid: userID), \(bind: type), \(uuid: actorID), \(uuid: postID), \(uuid: communityID),
                        \(uuid: conversationID), \(bind: refs.entityType), \(uuid: refs.entityID), \(bind: refs.groupKey),
                        \(bind: plJSON)::jsonb)
                """ + returningRow).first(decoding: NotificationsController.Row.self)
            if let row {
                hub.emitToUser(userID, event: "notification", rawJSON: NotificationsController.toDTOJSON(row))
                await emitCounts(userID, on: db, hub: hub)
            }
            return true
        } catch {
            logger.warning("pushUserNotification failed (\(type)): \(error)")
            return false
        }
    }

    // MARK: pushToMany (createBulkForUsers + emit)

    @discardableResult
    static func pushToMany(userIDs: [String], type: String, actorID: String? = nil, conversationID: String? = nil,
                           entityID: String? = nil, groupTargetID: String? = nil, payload: [String: Any] = [:],
                           on db: any SQLDatabase, hub: SocketHub, logger: Logger) async -> Int {
        guard NotificationsController.types[type] != nil else { return 0 }
        let recipients = Array(Set(userIDs.filter { !$0.isEmpty }))
        guard !recipients.isEmpty else { return 0 }
        do {
            let refs = resolveRefs(type: type, entityType: nil, entityID: entityID, groupTargetID: groupTargetID,
                                   postID: nil, conversationID: conversationID, communityID: nil)
            var pl = payload
            if let aid = actorID, pl["fromUserId"] == nil {
                let mode = await actorMode(type: type, given: nil, postID: nil, conversationID: conversationID,
                                           communityID: nil, on: db)
                for (k, v) in try await actorPayload(aid, mode: mode, on: db) { pl[k] = v }
            }
            let plJSON = String(data: (try? JSONSerialization.data(withJSONObject: pl)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            let rows = try await db.raw("""
                INSERT INTO user_notifications
                  (user_id, type, actor_id, conversation_id, entity_type, entity_id, group_key, payload)
                SELECT uid, \(bind: type), \(uuid: actorID), \(uuid: conversationID), \(bind: refs.entityType),
                       \(uuid: refs.entityID), \(bind: refs.groupKey), \(bind: plJSON)::jsonb
                FROM UNNEST(\(bind: recipients)::uuid[]) AS uid
                """ + returningRow).all(decoding: NotificationsController.Row.self)
            for row in rows.prefix(500) {
                hub.emitToUser(row.user_id, event: "notification", rawJSON: NotificationsController.toDTOJSON(row))
                await emitCounts(row.user_id, on: db, hub: hub)
            }
            return rows.count
        } catch {
            logger.warning("pushToMany failed (\(type)): \(error)")
            return 0
        }
    }

    // MARK: chat

    /// `notifyNewMessage`, a meeting proposal raises its own `meeting_proposed`
    /// row (with the proposal detail); everything else is the collapsed
    /// per-conversation "new message" row.
    static func notifyNewMessage(conversationID: String, senderID: String, message: MessageObject,
                                 on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        if message.message_type == "meeting", let mp = message.meeting_proposal {
            await pushChatNotification(conversationID: conversationID, type: "meeting_proposed", actorID: senderID,
                entityID: mp.id,
                payload: [
                    "messageId": message.id, "proposalId": mp.id, "title": mp.title,
                    "startsAt": JSONCoding.isoFractional.string(from: mp.starts_at),
                    "endsAt": mp.ends_at.map { JSONCoding.isoFractional.string(from: $0) } as Any,
                    "location": mp.location as Any,
                ],
                on: db, hub: hub, logger: logger)
            return
        }
        await pushMessageNotification(conversationID: conversationID, senderID: senderID, message: message,
                                     on: db, hub: hub, logger: logger)
    }

    static func pushMessageNotification(conversationID: String, senderID: String, message: MessageObject,
                                        on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        do {
            guard let conv = try await ChatStore.conversationByID(conversationID, on: db) else { return }
            var card = try await buildConversationCard(conv, actorID: senderID, on: db)
            card["lastMessageId"] = message.id
            card["lastMessageType"] = message.message_type
            card["preview"] = messagePreview(message) as Any
            let groupKey = "message:\(conversationID)"
            let plJSON = String(data: (try? JSONSerialization.data(withJSONObject: card)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            let rows = try await db.raw("""
                INSERT INTO user_notifications
                  (user_id, type, actor_id, conversation_id, entity_type, entity_id, group_key, payload)
                SELECT cp.user_id, 'message', \(uuid: senderID), \(uuid: conversationID), 'conversation',
                       \(uuid: conversationID), \(bind: groupKey), \(bind: plJSON)::jsonb
                FROM conversation_participants cp
                WHERE cp.conversation_id = \(uuid: conversationID) AND cp.user_id <> \(uuid: senderID)
                  AND (cp.muted_until IS NULL OR cp.muted_until <= NOW())
                ON CONFLICT (user_id, conversation_id) WHERE type = 'message'
                DO UPDATE SET
                  collapse_count = CASE WHEN user_notifications.is_read THEN 1 ELSE user_notifications.collapse_count + 1 END,
                  is_read = FALSE, actor_id = EXCLUDED.actor_id, payload = EXCLUDED.payload, updated_at = NOW()
                """ + returningRow).all(decoding: NotificationsController.Row.self)
            for row in rows.prefix(500) {
                hub.emitToUser(row.user_id, event: "notification", rawJSON: NotificationsController.toDTOJSON(row))
                await emitCounts(row.user_id, on: db, hub: hub)
            }
        } catch {
            logger.warning("pushMessageNotification failed: \(error)")
        }
    }

    /// A non-message chat event (meeting proposal/rsvp, reaction, group add).
    static func pushChatNotification(conversationID: String, type: String, actorID: String, userIDs: [String]? = nil,
                                     entityID: String? = nil, groupTargetID: String? = nil, payload: [String: Any] = [:],
                                     on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        do {
            let candidates: [String]
            if let u = userIDs { candidates = u } else { candidates = try await ChatStore.participants(conversationID, on: db) }
            let recipients = candidates.filter { !$0.isEmpty && $0 != actorID }
            guard !recipients.isEmpty else { return }
            guard let conv = try await ChatStore.conversationByID(conversationID, on: db) else { return }
            var pl = try await buildConversationCard(conv, actorID: actorID, on: db)
            for (k, v) in payload { pl[k] = v }
            _ = await pushToMany(userIDs: recipients, type: type, actorID: actorID, conversationID: conversationID,
                                 entityID: entityID, groupTargetID: groupTargetID, payload: pl,
                                 on: db, hub: hub, logger: logger)
        } catch {
            logger.warning("pushChatNotification failed (\(type)): \(error)")
        }
    }

    static func clearConversationNotification(conversationID: String, userID: String,
                                              on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        do {
            struct R: Decodable { let id: String }
            let ids = try await db.raw("""
                UPDATE user_notifications SET is_read = TRUE, collapse_count = 1
                WHERE user_id = \(uuid: userID) AND conversation_id = \(uuid: conversationID)
                  AND type = 'message' AND is_read = FALSE
                RETURNING id::text AS id
                """).all(decoding: R.self).map(\.id)
            guard !ids.isEmpty else { return }
            hub.emitToUser(userID, event: "notification_read", ReadPayload(ids: ids, isRead: true))
            await emitCounts(userID, on: db, hub: hub)
        } catch {
            logger.warning("clearConversationNotification failed: \(error)")
        }
    }
    struct ReadPayload: Content { var ids: [String]; var isRead: Bool }

    // MARK: helpers

    /// Who did it, as they appear in `mode`: a Work notification must show the
    /// Work name and photo, never the Hobby (or legacy) ones. `mode` nil (not
    /// known for this notification) falls back to the account's base name.
    static func actorPayload(_ actorID: String, mode: String?, on db: any SQLDatabase) async throws -> [String: Any] {
        struct A: Decodable { let display_name: String?; let avatar_color: String?; let avatar_url: String? }
        // A fixed literal, never user input: `mode` is checked against the two values.
        let modeRef = mode.flatMap { ["hobby", "work"].contains($0) ? "'\($0)'" : nil }
        let name = modeRef.map { PersonaSQL.expr("display_name", modeRef: $0) } ?? "u.display_name"
        let avatar = modeRef.map { PersonaSQL.expr("avatar_url", modeRef: $0) } ?? "u.avatar_url"
        let a = try await db.raw("""
            SELECT \(unsafeRaw: name) AS display_name, u.avatar_color, \(unsafeRaw: avatar) AS avatar_url
            FROM users u WHERE u.id = \(uuid: actorID)
            """).first(decoding: A.self)
        return [
            "fromUserId": actorID,
            "fromDisplayName": a?.display_name as Any,
            "fromAvatarColor": a?.avatar_color as Any,
            "fromAvatarUrl": a?.avatar_url as Any,
        ]
    }

    /// Which persona a notification is about: given by the caller, implied by
    /// a Work-only type, or the mode of the post, chat or community it points at.
    static func actorMode(type: String, given: String?, postID: String?, conversationID: String?,
                          communityID: String?, on db: any SQLDatabase) async -> String? {
        if let given, ["hobby", "work"].contains(given) { return given }
        if ["skill_endorsed", "job_application", "application_status"].contains(type) { return "work" }
        struct M: Decodable { let mode: String? }
        if let postID {
            return try? await db.raw("SELECT mode FROM posts WHERE id = \(uuid: postID)").first(decoding: M.self)?.mode
        }
        if let conversationID {
            return try? await db.raw("SELECT mode FROM conversations WHERE id = \(uuid: conversationID)").first(decoding: M.self)?.mode
        }
        if let communityID {
            return try? await db.raw("""
                SELECT CASE WHEN type = 'work' THEN 'work' ELSE 'hobby' END AS mode FROM communities WHERE id = \(uuid: communityID)
                """).first(decoding: M.self)?.mode
        }
        return nil
    }

    static func buildConversationCard(_ conv: ChatStore.ConvBasic, actorID: String, on db: any SQLDatabase) async throws -> [String: Any] {
        var card: [String: Any] = [
            "conversationId": conv.id, "isGroup": conv.is_group, "mode": conv.mode,
        ]
        if conv.is_group {
            struct C: Decodable { let n: Int }
            let n = try await db.raw("SELECT COUNT(*)::int AS n FROM conversation_participants WHERE conversation_id = \(uuid: conv.id)")
                .first(decoding: C.self)?.n ?? 0
            card["groupName"] = conv.name as Any
            card["groupAvatarUrl"] = conv.avatar_url as Any
            card["groupAvatarColor"] = conv.avatar_color as Any
            card["memberCount"] = n
        } else {
            struct S: Decodable { let display_name: String?; let avatar_url: String?; let avatar_color: String? }
            let s = try await db.raw("""
                SELECT \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'\(conv.mode)'")) AS display_name,
                  \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'\(conv.mode)'")) AS avatar_url, avatar_color
                FROM users u WHERE id = \(uuid: actorID)
                """).first(decoding: S.self)
            card["peerUserId"] = actorID
            card["peerDisplayName"] = s?.display_name as Any
            card["peerAvatarUrl"] = s?.avatar_url as Any
            card["peerAvatarColor"] = s?.avatar_color as Any
        }
        return card
    }

    /// Fire-and-forget a notification side effect from a REST handler, Node
    /// never awaits these, so neither do we (keeps response latency parity).
    static func fireAndForget(_ req: Request, _ work: @escaping @Sendable (any SQLDatabase, SocketHub, Logger) async -> Void) {
        let db = req.application.db, hub = req.application.socketHub, log = req.logger
        Task { await work(db.sql(), hub, log) }
    }

    /// A "someone interacted with your thing" notification (post_liked /
    /// post_commented / comment_replied / comment_liked / post_shared /
    /// connection_request / connection_accepted). Never delivered inline: it
    /// goes onto the queue with a ~3s `delayUntil`, and `SocialNotifyJob`
    /// re-checks that the like / comment / request still exists before writing
    /// the row, so an accidental tap that's undone within the window notifies
    /// nobody. With `RUN_JOBS` unset there's no queue, so it falls back to an
    /// immediate fire-and-forget through the same delivery body (still deduped,
    /// just without the cancel window).
    static func dispatchSocial(_ req: Request, _ payload: BackgroundJobs.SocialNotifyJob.Payload) {
        guard payload.actorID != payload.recipientID else { return }
        let app = req.application
        let logger = req.logger
        if BackgroundJobs.enabled {
            Task {
                do {
                    try await app.queues.queue.dispatch(
                        BackgroundJobs.SocialNotifyJob.self, payload,
                        maxRetryCount: 3, delayUntil: Date().addingTimeInterval(3))
                } catch {
                    logger.warning("dispatchSocial(\(payload.type)) enqueue failed: \(error)")
                }
            }
        } else {
            let db = app.db.sql(), hub = app.socketHub
            Task { await BackgroundJobs.SocialNotifyJob.deliver(payload, on: db, hub: hub, logger: logger) }
        }
    }

    /// A post just went live in a community: tell the members whose level
    /// asks for it. Detached, it never holds up or fails the post.
    static func communityNewPost(app: Application, postID: String, communityID: String, authorID: String,
                                 logger: Logger) {
        let db = app.db.sql(), hub = app.socketHub
        Task {
            do {
                let recipients = try await CommunityStore.newPostRecipients(communityID, author: authorID, on: db)
                guard !recipients.isEmpty else { return }
                struct N: Decodable { let name: String }
                let name = try await db.raw("SELECT name FROM communities WHERE id = \(uuid: communityID)")
                    .first(decoding: N.self)?.name ?? ""
                for user in recipients {
                    _ = await pushUserNotification(userID: user, type: "new_post", actorID: authorID, postID: postID,
                                                   communityID: communityID, payload: ["communityName": name],
                                                   on: db, hub: hub, logger: logger)
                }
            } catch {
                logger.warning("community new_post for \(postID) failed: \(error)")
            }
        }
    }

    static func messagePreview(_ m: MessageObject) -> String? {
        switch m.message_type {
        case "image": return "📷 Photo"
        case "album":
            if let c = m.content, !c.isEmpty { return "📷 " + String(c.prefix(previewLength)) }
            return "📷 \(m.media_items?.count ?? 2) photos"
        case "video": return "🎥 Video"
        case "voice": return "🎤 Voice message"
        case "poll": return "📊 " + String((m.content ?? "").prefix(previewLength))
        case "post":
            let note = m.content?.trimmedText ?? ""
            return note.isEmpty ? "📰 Shared a post" : "📰 " + String(note.prefix(previewLength))
        case "community":
            let note = m.content?.trimmedText ?? ""
            return note.isEmpty ? "👥 Shared a community" : "👥 " + String(note.prefix(previewLength))
        default:
            let c = m.content ?? ""
            return c.isEmpty ? nil : String(c.prefix(previewLength))
        }
    }
}

