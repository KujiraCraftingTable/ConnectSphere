import Foundation

/// Posted after a successful "leave group" call so screens still open
/// underneath the one that performed it (`ChatSettingsView`, `ChatView`) can
/// navigate back out together. Mirrors `UserRepository`'s
/// `.userBlockStatusChanged` cross-screen sync pattern. `userInfo["conversationId"]`
/// carries which conversation was left.
extension Notification.Name {
    /// Ask Messages to open a conversation; `object` is a `ChatRoute` (e.g. a
    /// group just created from a 1-on-1 chat's settings).
    static let openConversation = Notification.Name("openConversation")
    static let userLeftGroupConversation = Notification.Name("MessageRepository.userLeftGroupConversation")
}

struct MessageRepository {
    private let client = NetworkClient.shared

    // MARK: - Conversations

    /// Open or retrieve a 1-on-1 conversation with another user in the given mode.
    func openConversation(otherUserId: String, mode: String, token: String) async throws -> String {
        struct Body: Encodable { let other_user_id: String; let mode: String }
        struct ConvResponse: Decodable { let id: String }

        let body = try JSONEncoder().encode(Body(other_user_id: otherUserId, mode: mode))
        let response = try await client.fetch(
            DataResponse<ConvResponse>.self,
            path: "/messages/conversations",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data.id
    }

    /// Fetch all conversations for the current user in a given mode.
    func fetchConversations(mode: String, token: String) async throws -> [Conversation] {
        let key = CacheStore.Key.conversations(mode)
        do {
            let (response, body) = try await client.fetchRaw(
                DataListResponse<Conversation>.self,
                path: "/messages/conversations",
                method: "GET",
                token: token,
                queryItems: [URLQueryItem(name: "mode", value: mode)]
            )
            await CacheStore.shared.put(key, body: body)
            return response.data
        } catch {
            if let cached = await CacheStore.shared.get(DataListResponse<Conversation>.self, key) {
                return cached.data
            }
            throw error
        }
    }

    // MARK: - Group conversations

    /// Create a new group conversation with the given members (and optional name).
    /// Returns the new conversation's id. The create response's shape is narrower
    /// than a list-endpoint `Conversation` row (no `updated_at`/last-message/
    /// unread-count columns yet. It has `created_at` instead), so only the id
    /// is decoded here rather than the full `Conversation` model.
    func createGroup(memberIds: [String], mode: String, name: String?, token: String) async throws -> String {
        struct Body: Encodable { let member_ids: [String]; let mode: String; let name: String? }
        struct CreateResponse: Decodable { let id: String }
        let body = try JSONEncoder().encode(Body(member_ids: memberIds, mode: mode, name: name))
        let response = try await client.fetch(
            DataResponse<CreateResponse>.self,
            path: "/messages/conversations/group",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data.id
    }

    /// Add members to an existing group. Owner-only server-side (403 otherwise).
    func addMembers(conversationId: String, memberIds: [String], token: String) async throws -> ConversationSettings {
        struct Body: Encodable { let member_ids: [String] }
        let body = try JSONEncoder().encode(Body(member_ids: memberIds))
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/members",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data
    }

    /// Remove a member from a group. Owner-only server-side.
    func removeMember(conversationId: String, userId: String, token: String) async throws -> ConversationSettings {
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/members/\(userId)",
            method: "DELETE",
            token: token
        )
        return response.data
    }

    /// Promote another member to owner. Owner-only server-side; transfers away
    /// the caller's own owner role.
    func promoteOwner(conversationId: String, userId: String, token: String) async throws -> ConversationSettings {
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/members/\(userId)/promote",
            method: "POST",
            token: token
        )
        return response.data
    }

    /// Update the group's name/photo. Owner-only server-side.
    func updateGroup(
        conversationId: String, name: String?, avatarUrl: String?, avatarColor: String?, token: String
    ) async throws -> ConversationSettings {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let avatarUrl { body["avatar_url"] = avatarUrl }
        if let avatarColor { body["avatar_color"] = avatarColor }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/group",
            method: "PATCH",
            token: token,
            bodyData: bodyData
        )
        return response.data
    }

    /// Leave a group conversation. Any member may call this.
    func leaveGroup(conversationId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/leave",
            method: "POST",
            token: token
        )
    }

    // MARK: - Block alert (groups only, 1:1 always returns shouldAlert: false)

    /// Whether the current user should be alerted that someone they've blocked
    /// (or who's blocked them) is in this group.
    func fetchBlockAlertState(conversationId: String, token: String) async throws -> (shouldAlert: Bool, blockedUserIds: [String]) {
        struct StateResponse: Decodable { let shouldAlert: Bool; let blockedUserIds: [String]? }
        let response = try await client.fetch(
            StateResponse.self,
            path: "/messages/conversations/\(conversationId)/block-alert-state",
            method: "GET",
            token: token
        )
        return (response.shouldAlert, response.blockedUserIds ?? [])
    }

    /// Acknowledge the current blocked-set for this group so the alert doesn't
    /// re-fire until it changes (e.g. a newly-added member is also blocked).
    func acknowledgeBlockAlert(conversationId: String, token: String) async throws {
        struct AckResult: Decodable { let acked: Bool }
        _ = try await client.fetch(
            DataResponse<AckResult>.self,
            path: "/messages/conversations/\(conversationId)/block-alert-ack",
            method: "POST",
            token: token
        )
    }

    // MARK: - Messages

    /// Fetch messages for a conversation. Pass `before` ISO date for cursor pagination.
    func fetchMessages(
        conversationId: String,
        limit: Int = 30,
        before: Date? = nil,
        token: String
    ) async throws -> [Message] {
        var items = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let before {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(URLQueryItem(name: "before", value: formatter.string(from: before)))
        }
        let response = try await client.fetch(
            DataListResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "GET",
            token: token,
            queryItems: items
        )
        return response.data
    }

    /// Send a message via REST (fallback when socket is unavailable).
    /// `voiceDurationSeconds`/`voiceWaveform` are only ever set for `.voice`
    /// messages, mirroring how `mediaUrl` is already optional for every
    /// other type.
    func sendMessage(
        conversationId: String,
        content: String?,
        messageType: MessageType,
        mediaUrl: String? = nil,
        mediaItems: [MessageMediaItem]? = nil,
        replyToMessageId: String? = nil,
        voiceDurationSeconds: Int? = nil,
        voiceWaveform: [Float]? = nil,
        /// The person saw "Are you sure?" about rude wording and sent it anyway.
        confirmed: Bool = false,
        /// Sent by Forward: the receiver sees "Forwarded" and nothing about the source.
        isForwarded: Bool = false,
        token: String
    ) async throws -> Message {
        struct Body: Encodable {
            let content: String?
            let message_type: String
            let media_url: String?
            let media_items: [MessageMediaItem]?
            let reply_to_message_id: String?
            let voice_duration_seconds: Int?
            let voice_waveform: [Float]?
            let confirm: Bool?
            let is_forwarded: Bool?
        }
        let body = try JSONEncoder().encode(Body(
            content: content,
            message_type: messageType.rawValue,
            media_url: mediaUrl,
            media_items: mediaItems,
            reply_to_message_id: replyToMessageId,
            voice_duration_seconds: voiceDurationSeconds,
            voice_waveform: voiceWaveform,
            confirm: confirmed ? true : nil,
            is_forwarded: isForwarded ? true : nil
        ))
        let response = try await client.fetch(
            DataResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data
    }

    /// Upload an image or video and return the hosted URL and detected type.
    func uploadMedia(fileURL: URL, token: String) async throws -> (url: String, type: MessageType) {
        struct UploadResponse: Decodable {
            let url: String
            let message_type: String
        }

        // Photos and videos lose their GPS/camera/date metadata before they
        // leave the phone. Voice notes come from our own recorder and carry none.
        let data: Data, ext: String, mime: String
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            (data, ext, mime) = (try Data(contentsOf: fileURL), "m4a", "audio/m4a")
        case "mp4", "mov":
            let clean = try await MediaSanitizer.cleanVideo(at: fileURL)
            defer { try? FileManager.default.removeItem(at: clean.url) }
            (data, ext, mime) = (try Data(contentsOf: clean.url), clean.url.pathExtension, clean.mimeType)
        default:
            let clean = try await MediaSanitizer.cleanImage(try Data(contentsOf: fileURL))
            (data, ext, mime) = (clean.data, clean.fileExtension, clean.mimeType)
        }

        let boundary = UUID().uuidString
        var body = Data()

        // Multipart form-data boundary
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"upload.\(ext)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: APIConfig.baseURL + "/messages/upload") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(DataResponse<UploadResponse>.self, from: responseData)
        let msgType = MessageType(rawValue: decoded.data.message_type) ?? .image
        return (decoded.data.url, msgType)
    }

    /// Recall one of my own messages (soft delete on both sides)
    func recallMessage(conversationId: String, messageId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)",
            method: "DELETE",
            token: token
        )
    }

    /// Edits one of my text messages; returns the updated message.
    func editMessage(conversationId: String, messageId: String, content: String, token: String) async throws -> Message {
        struct Body: Encodable { let content: String }
        struct Response: Decodable { let data: Message }
        return try await client.fetch(
            Response.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)",
            method: "PATCH",
            token: token,
            bodyData: try JSONEncoder().encode(Body(content: content))
        ).data
    }

    // MARK: - Reactions

    /// React to a message (toggle off if re-tapping the same emoji, else set/replace).
    /// Returns the message's fresh reaction summary: emoji → user ids.
    @discardableResult
    func react(conversationId: String, messageId: String, emoji: String, token: String) async throws -> [String: [String]] {
        struct Body: Encodable { let emoji: String }
        struct ReactionsResponse: Decodable { let reactions: [String: [String]] }

        let body = try JSONEncoder().encode(Body(emoji: emoji))
        let response = try await client.fetch(
            DataResponse<ReactionsResponse>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/reactions",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data.reactions
    }

    // MARK: - Meeting proposals

    /// Propose a meeting inside the conversation (REST fallback for socket
    /// `send_message` with message_type "meeting"). Returns the created message
    /// with its embedded `meeting_proposal`. Server expects the proposal fields
    /// nested under `meeting_proposal` (see `messageController.sendMessage`).
    /// `reminderOffset` is the raw preset key ("on_day"/"1_day_before"/
    /// "2_days_before"/"1_week_before"); `reminderAt` is the absolute instant
    /// computed client-side (see `MeetingReminderOffset.reminderDate(before:)`).
    func sendMeetingProposal(
        conversationId: String,
        title: String,
        location: String?,
        startsAt: Date,
        endsAt: Date?,
        reminderOffset: String,
        reminderAt: Date,
        token: String
    ) async throws -> Message {
        let iso = ISO8601DateFormatter()
        var proposalDict: [String: Any] = [
            "title": title,
            "starts_at": iso.string(from: startsAt),
            "reminder_offset": reminderOffset,
            "reminder_at": iso.string(from: reminderAt)
        ]
        if let location, !location.isEmpty { proposalDict["location"] = location }
        if let endsAt { proposalDict["ends_at"] = iso.string(from: endsAt) }
        let dict: [String: Any] = [
            "message_type": "meeting",
            "meeting_proposal": proposalDict
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let response = try await client.fetch(
            DataResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data
    }

    /// Reschedule an existing meeting proposal. Only the proposer may call this;
    /// the server clears prior RSVPs (and resets `reminder_sent_at`) so
    /// participants re-respond and the reminder re-arms against the new time.
    /// Server returns just the updated proposal (not the whole message).
    func updateMeetingProposal(
        conversationId: String,
        messageId: String,
        title: String,
        location: String?,
        startsAt: Date,
        endsAt: Date?,
        reminderOffset: String,
        reminderAt: Date,
        token: String
    ) async throws -> MeetingProposal {
        let iso = ISO8601DateFormatter()
        let dict: [String: Any] = [
            "title": title,
            "starts_at": iso.string(from: startsAt),
            "location": (location?.isEmpty == false) ? location! : NSNull(),
            "ends_at": endsAt.map { iso.string(from: $0) } ?? NSNull(),
            "reminder_offset": reminderOffset,
            "reminder_at": iso.string(from: reminderAt)
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let response = try await client.fetch(
            DataResponse<MeetingProposal>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/meeting-proposal",
            method: "PATCH",
            token: token,
            bodyData: body
        )
        return response.data
    }

    /// Cancel a meeting proposal. Only the proposer may call this. Server
    /// returns just the updated proposal (not the whole message).
    func cancelMeetingProposal(conversationId: String, messageId: String, token: String) async throws -> MeetingProposal {
        let response = try await client.fetch(
            DataResponse<MeetingProposal>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/meeting-proposal/cancel",
            method: "POST",
            token: token
        )
        return response.data
    }

    /// Sends a group poll: the question is the message content.
    func sendPoll(conversationId: String, question: String, options: [String], endsAt: Date?,
                  token: String) async throws -> Message {
        struct PollIn: Encodable { let options: [String]; let ends_at: String? }
        struct Body: Encodable { let content: String; let message_type: String; let poll: PollIn }
        let body = try JSONEncoder().encode(Body(
            content: question, message_type: MessageType.poll.rawValue,
            poll: PollIn(options: options, ends_at: endsAt.map { ISO8601DateFormatter().string(from: $0) })))
        return try await client.fetch(
            DataResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "POST", token: token, bodyData: body
        ).data
    }

    /// Shares a community into a chat, with an optional note from the sender.
    func sendCommunity(conversationId: String, communityId: String, note: String, token: String) async throws -> Message {
        struct Body: Encodable { let content: String?; let message_type: String; let shared_community_id: String }
        let body = try JSONEncoder().encode(Body(content: note.isEmpty ? nil : note,
                                                 message_type: MessageType.community.rawValue, shared_community_id: communityId))
        return try await client.fetch(
            DataResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "POST", token: token, bodyData: body
        ).data
    }

    /// Shares a post into a chat, with an optional note from the sender.
    func sendPost(conversationId: String, postId: String, note: String, token: String) async throws -> Message {
        struct Body: Encodable { let content: String?; let message_type: String; let shared_post_id: String }
        let body = try JSONEncoder().encode(Body(content: note.isEmpty ? nil : note,
                                                 message_type: MessageType.post.rawValue, shared_post_id: postId))
        return try await client.fetch(
            DataResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "POST", token: token, bodyData: body
        ).data
    }

    /// Votes on a group poll, or moves your vote to `optionId`; returns the
    /// updated poll.
    func votePoll(conversationId: String, messageId: String, optionId: String, token: String) async throws -> ChatPoll {
        struct Body: Encodable { let option_id: String }
        let body = try JSONEncoder().encode(Body(option_id: optionId))
        return try await client.fetch(
            DataResponse<ChatPoll>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/poll-vote",
            method: "POST", token: token, bodyData: body
        ).data
    }

    /// Takes your vote on a group poll back; returns the updated poll.
    func unvotePoll(conversationId: String, messageId: String, token: String) async throws -> ChatPoll {
        try await client.fetch(
            DataResponse<ChatPoll>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/poll-vote",
            method: "DELETE", token: token
        ).data
    }

    /// RSVP to a meeting proposal ("going" | "maybe" | "not_going"). Server
    /// returns just the updated proposal (not the whole message).
    @discardableResult
    func respondToMeeting(conversationId: String, messageId: String, status: String, token: String) async throws -> MeetingProposal {
        struct Body: Encodable { let status: String }
        let body = try JSONEncoder().encode(Body(status: status))
        let response = try await client.fetch(
            DataResponse<MeetingProposal>.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)/meeting-response",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data
    }

    // MARK: - Pinned messages
    // NOTE: response/body field names assumed per the Phase 4 plan's working
    // shape (parallel backend task not landed at write time). Reconcile
    // against the real controller once it lands. See `PinnedMessage`.

    /// Fetch all pins for a conversation (server caps at 10, ordered newest-pinned first).
    func fetchPins(conversationId: String, token: String) async throws -> [PinnedMessage] {
        let response = try await client.fetch(
            DataListResponse<PinnedMessage>.self,
            path: "/messages/conversations/\(conversationId)/pins",
            method: "GET",
            token: token
        )
        return response.data
    }

    /// Pin a message (REST fallback for socket `pin_message`). `expiresAt`
    /// nil means "never expires". 400s server-side once the conversation
    /// already has 10 pins. The POST response is the raw `message_pins` row
    /// (no joined sender_name/message_type/content), which doesn't satisfy
    /// `PinnedMessage`'s required fields, don't try to decode it as one;
    /// the caller should refetch via `fetchPins` for the properly-joined row.
    func pinMessage(conversationId: String, messageId: String, expiresAt: Date?, token: String) async throws {
        struct PinResult: Decodable { let id: String }
        var body: [String: Any] = ["message_id": messageId]
        if let expiresAt {
            body["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await client.fetch(
            DataResponse<PinResult>.self,
            path: "/messages/conversations/\(conversationId)/pins",
            method: "POST",
            token: token,
            bodyData: bodyData
        )
    }

    /// Unpin a message. Any participant may call this (not owner-only).
    func unpinMessage(conversationId: String, messageId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/pins/\(messageId)",
            method: "DELETE",
            token: token
        )
    }

    // MARK: - Read receipt

    /// Mark all messages in a conversation as read (REST call; socket also handles this).
    func markRead(conversationId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/read",
            method: "PUT",
            token: token
        )
    }

    /// Mark all sent messages in a conversation as delivered (REST catch-up for
    /// messages that arrived while the recipient's socket was offline. The live
    /// path is handled by the `message_delivered` socket event instead).
    func markDelivered(conversationId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/delivered",
            method: "PUT",
            token: token
        )
    }

    /// Total unread message count for the badge on the chat icon.
    /// Accept a message request. The chat moves from Waiting to my inbox.
    func acceptRequest(conversationId: String, token: String) async throws {
        struct Accepted: Decodable { let accepted: Bool }
        _ = try await client.fetch(Accepted.self, path: "/messages/conversations/\(conversationId)/accept",
                                   method: "POST", token: token)
    }

    /// Pin or unpin a conversation at the top of my own list.
    func setPinned(conversationId: String, pinned: Bool, token: String) async throws {
        struct Body: Encodable { let pinned: Bool }
        struct State: Decodable { let pinned: Bool? }
        _ = try await client.fetch(State.self, path: "/messages/conversations/\(conversationId)/pin", method: "PUT",
                                   token: token, bodyData: try JSONEncoder().encode(Body(pinned: pinned)))
    }

    /// Archive or unarchive a conversation in my own list.
    func setArchived(conversationId: String, archived: Bool, token: String) async throws {
        struct Body: Encodable { let archived: Bool }
        struct State: Decodable { let archived: Bool? }
        _ = try await client.fetch(State.self, path: "/messages/conversations/\(conversationId)/archive", method: "PUT",
                                   token: token, bodyData: try JSONEncoder().encode(Body(archived: archived)))
    }

    func fetchUnreadCount(mode: String, token: String) async throws -> Int {
        struct CountResponse: Decodable { let count: Int }
        let response = try await client.fetch(
            DataResponse<CountResponse>.self,
            path: "/messages/unread",
            method: "GET",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode)]
        )
        return response.data.count
    }

    // MARK: - Conversation settings

    /// Fetch shared settings (theme, other person's nickname) + my mute state.
    func fetchSettings(conversationId: String, token: String) async throws -> ConversationSettings {
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/settings",
            method: "GET",
            token: token
        )
        return response.data
    }

    /// The chat's theme and nickname notes, oldest first.
    func fetchEvents(conversationId: String, token: String) async throws -> [ChatEvent] {
        try await client.fetch(
            DataListResponse<ChatEvent>.self,
            path: "/messages/conversations/\(conversationId)/events",
            method: "GET",
            token: token
        ).data
    }

    /// PATCH shared settings with a body that can carry an explicit null.
    private func patchSettings(conversationId: String, body: [String: Any], token: String) async throws -> ConversationSettings {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response = try await client.fetch(
            DataResponse<ConversationSettings>.self,
            path: "/messages/conversations/\(conversationId)/settings",
            method: "PATCH",
            token: token,
            bodyData: bodyData
        )
        return response.data
    }

    /// Update the shared chat theme (nil resets to the app default).
    func updateTheme(conversationId: String, theme: String?, token: String) async throws -> ConversationSettings {
        try await patchSettings(conversationId: conversationId, body: ["theme": theme.map { $0 as Any } ?? NSNull()], token: token)
    }

    /// Update the shared nickname for the other person (nil clears it).
    func updateNickname(conversationId: String, nickname: String?, token: String) async throws -> ConversationSettings {
        try await patchSettings(conversationId: conversationId, body: ["nickname": nickname.map { $0 as Any } ?? NSNull()], token: token)
    }

    /// Set my mute for the conversation. `minutes`: nil = unmute, negative = until
    /// turned back on, N>0 = N minutes. Returns the new muted-until date (if any).
    @discardableResult
    func setMute(conversationId: String, minutes: Int?, token: String) async throws -> Date? {
        struct MuteResult: Decodable {
            let mutedUntil: Date?
            enum CodingKeys: String, CodingKey { case mutedUntil = "muted_until" }
        }
        let bodyData = try JSONSerialization.data(withJSONObject: ["minutes": minutes.map { $0 as Any } ?? NSNull()])
        let response = try await client.fetch(
            DataResponse<MuteResult>.self,
            path: "/messages/conversations/\(conversationId)/mute",
            method: "PUT",
            token: token,
            bodyData: bodyData
        )
        return response.data.mutedUntil
    }

    /// Images/videos sent in the conversation, newest first.
    func fetchMedia(conversationId: String, token: String) async throws -> [ChatMediaItem] {
        let response = try await client.fetch(
            DataListResponse<ChatMediaItem>.self,
            path: "/messages/conversations/\(conversationId)/media",
            method: "GET",
            token: token
        )
        return response.data
    }

    /// Keyword search over the conversation's text messages.
    func searchMessages(conversationId: String, query: String, token: String) async throws -> [Message] {
        let response = try await client.fetch(
            DataListResponse<Message>.self,
            path: "/messages/conversations/\(conversationId)/messages/search",
            method: "GET",
            token: token,
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
        return response.data
    }

    /// Cross-conversation search, conversation name AND message content,
    /// across every conversation the user participates in for this mode.
    func searchAll(mode: String, query: String, token: String) async throws -> [ConversationSearchHit] {
        let response = try await client.fetch(
            DataListResponse<ConversationSearchHit>.self,
            path: "/messages/search",
            method: "GET",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "q", value: query)]
        )
        return response.data
    }

    /// Clear the conversation on my side only (sets my cleared_at server-side).
    func clearConversation(conversationId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/messages",
            method: "DELETE",
            token: token
        )
    }
}
