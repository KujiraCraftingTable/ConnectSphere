import Foundation

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
        let response = try await client.fetch(
            DataListResponse<Conversation>.self,
            path: "/messages/conversations",
            method: "GET",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode)]
        )
        return response.data
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
    func sendMessage(
        conversationId: String,
        content: String?,
        messageType: MessageType,
        mediaUrl: String? = nil,
        replyToMessageId: String? = nil,
        token: String
    ) async throws -> Message {
        struct Body: Encodable {
            let content: String?
            let message_type: String
            let media_url: String?
            let reply_to_message_id: String?
        }
        let body = try JSONEncoder().encode(Body(
            content: content,
            message_type: messageType.rawValue,
            media_url: mediaUrl,
            reply_to_message_id: replyToMessageId
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

        let data = try Data(contentsOf: fileURL)
        let ext  = fileURL.pathExtension.lowercased()
        let mime = ["mp4", "mov"].contains(ext) ? "video/mp4" : "image/jpeg"

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

    /// Thu hồi tin nhắn của mình (soft delete cả 2 phía)
    func recallMessage(conversationId: String, messageId: String, token: String) async throws {
        _ = try await client.fetch(
            OKResponse.self,
            path: "/messages/conversations/\(conversationId)/messages/\(messageId)",
            method: "DELETE",
            token: token
        )
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

    /// Total unread message count for the badge on the chat icon.
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
