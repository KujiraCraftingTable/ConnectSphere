import Foundation

/// Single access point for all post-related API calls.
/// ViewModels use this instead of calling NetworkClient directly.
struct PostRepository {
    private let client = NetworkClient.shared

    /// `filter`: nil = everything, "connections" = friends, "following" =
    /// people you follow who aren't friends.
    func fetchPosts(mode: AppMode, filter: String? = nil, limit: Int = 20, offset: Int = 0) async throws -> [Post] {
        let endpoint = Endpoint.listPosts(
            mode: mode.rawValue,
            filter: filter,
            limit: limit,
            offset: offset
        )
        // Only the first page of the unfiltered main feed is cached — that is
        // the airplane-mode landing surface. Filtered / paged requests skip it.
        let cacheable = filter == nil && offset == 0
        let key = CacheStore.Key.feed(mode.rawValue)
        do {
            let (response, body) = try await client.fetchRaw(PaginatedResponse<PostDTO>.self, from: endpoint)
            if cacheable { await CacheStore.shared.put(key, body: body) }
            return response.data.map { $0.toPost() }
        } catch {
            if cacheable, let cached = await CacheStore.shared.get(PaginatedResponse<PostDTO>.self, key) {
                return cached.data.map { $0.toPost() }
            }
            throw error
        }
    }

    /// Personalized newsfeed (recommendations) — paginated with a keyset cursor.
    /// Returns (posts, nextCursor); nextCursor = nil means there's no more page.
    func fetchRecommendedFeed(mode: AppMode, cursor: String?, limit: Int = 20) async throws -> (posts: [Post], nextCursor: String?) {
        let endpoint = Endpoint.recommendedFeed(mode: mode.rawValue, cursor: cursor, limit: limit)
        let cacheable = cursor == nil
        let key = CacheStore.Key.recommendedFeed(mode.rawValue)
        do {
            let (response, body) = try await client.fetchRaw(CursorResponse<PostDTO>.self, from: endpoint)
            if cacheable { await CacheStore.shared.put(key, body: body) }
            return (response.data.map { $0.toPost() }, response.nextCursor)
        } catch {
            if cacheable, let cached = await CacheStore.shared.get(CursorResponse<PostDTO>.self, key) {
                return (cached.data.map { $0.toPost() }, nil)   // no further pages offline
            }
            throw error
        }
    }

    /// Fetches a single post by id (used for the screen opened from a notification)
    func fetchPost(id: String) async throws -> Post {
        let response = try await client.fetch(
            SingleResponse<PostDTO>.self,
            from: .getPost(id: id)
        )
        return response.data.toPost()
    }

    /// Posts by hashtag (browse tag) — mode-scoped like every other post-list
    /// surface (main Feed, connections scope), so a tag chip tapped in Hobby mode
    /// doesn't pull in Work-mode posts sharing the same tag, and vice versa. The
    /// backend's `mode` filter on `GET /api/posts` already supports combining with
    /// `tag`; this was simply never passed from here before.
    func fetchPostsByTag(_ tag: String, mode: AppMode, limit: Int = 50, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(mode: mode.rawValue, tag: tag, limit: limit, offset: offset)
        )
        return response.data.map { $0.toPost() }
    }

    /// Free-text search over post content, mode-scoped like every other
    /// post-list surface — mirrors `fetchPostsByTag`'s shape.
    func searchPosts(_ query: String, mode: AppMode, limit: Int = 20, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(mode: mode.rawValue, search: query, limit: limit, offset: offset)
        )
        return response.data.map { $0.toPost() }
    }

    /// AI search over posts (local-LLM breakdown + embeddings server-side).
    /// Returns posts in ranked order plus post id → match score (0…1).
    func aiSearchPosts(_ prompt: String, mode: AppMode) async throws -> (posts: [Post], criteria: AISearchCriteriaDTO, warnings: [SearchWarningDTO], scores: [String: Double]) {
        let response = try await client.fetch(
            AIPostSearchResponseDTO.self,
            from: .aiPostSearch(query: prompt, mode: mode.rawValue)
        )
        return (response.data.map { $0.toPost() }, response.criteria, response.warnings, response.match_scores)
    }

    /// Shares/reposts a post; returns the new shared post
    func sharePost(postId: String, content: String, mode: AppMode) async throws -> Post {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        let body = NetworkClient.encode([
            "content": content,
            "mode":    mode.rawValue,
        ])
        let response = try await client.fetch(
            SingleResponse<PostDTO>.self,
            path: "/posts/\(postId)/share",
            method: "POST",
            token: token,
            bodyData: body
        )
        return response.data.toPost()
    }

    func analyzePost(content: String, currentMode: AppMode) async throws -> PostAnalyzeDTO {
        return try await client.fetch(
            PostAnalyzeDTO.self,
            from: .analyzePost(content: content, currentMode: currentMode.rawValue)
        )
    }

    func fetchLinkPreview(url: String) async throws -> LinkPreviewDTO {
        return try await client.fetch(
            LinkPreviewDTO.self,
            from: .linkPreview(url: url)
        )
    }

    /// Prefix-match hashtag suggestions for `HashtagInputView`'s debounced dropdown.
    /// `prefix` must be non-empty — the backend returns 400 if it's empty, so the caller
    /// (HashtagInputView) blocks the call itself when the text field is empty.
    func suggestTags(prefix: String, limit: Int = 8) async throws -> [TagSuggestionDTO] {
        let response = try await client.fetch(
            DataListResponse<TagSuggestionDTO>.self,
            from: .suggestTags(prefix: prefix, limit: limit)
        )
        return response.data
    }

    /// Creates a post and returns the new post's ID.
    /// The backend derives the author from the JWT, so author_id is no longer sent.
    /// `hashtags` are the user-typed tags, saved synchronously with `source = 'user'`.
    /// AI-generated tags are never shown; they only feed AI search server-side.
    func createPost(
        content: String,
        mode: AppMode,
        privacy: PostPrivacy,
        imageUrl: String? = nil,
        imageUrls: [String] = [],
        linkUrl: String? = nil,
        articleTitle: String? = nil,
        hashtags: [String] = []
    ) async throws -> Post {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }

        var body: [String: Any] = [
            "content":      content,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
        ]
        if let img = imageUrl      { body["image_url"]     = img }
        if !imageUrls.isEmpty      { body["image_urls"]    = imageUrls }
        if let lnk = linkUrl       { body["link_url"]      = lnk }
        if let ttl = articleTitle  { body["article_title"] = ttl }
        if !hashtags.isEmpty       { body["hashtags"]      = hashtags }

        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        // Decode the FULL post (same `PostDTO` shape `fetchPost(id:)` uses),
        // not just its id — the create response already carries everything
        // needed to render the post immediately, so the caller can insert it
        // straight into the feed instead of waiting on a separate reload.
        let response = try await client.fetch(
            SingleResponse<PostDTO>.self,
            path: "/posts",
            method: "POST",
            token: token,
            bodyData: bodyData
        )
        return response.data.toPost()
    }

    /// Soft-deletes a post — backend sets state = 'deleted', hiding the post from the feed
    func deletePost(postId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/posts/\(postId)",
            method: "DELETE",
            token: token
        )
    }

    /// Restore a soft-deleted post of your own — backend flips status back to
    /// 'posted' and clears deleted_at; 403 if you're not the author, 404 if it
    /// doesn't exist or isn't currently deleted. Used by the Undo toast and by
    /// "Recently Deleted"'s Restore button.
    func restorePost(postId: String) async throws -> Post {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct RestoreResponse: Decodable { let data: PostDTO }
        let response = try await client.fetch(
            RestoreResponse.self,
            path: "/posts/\(postId)/restore",
            method: "POST",
            token: token
        )
        return response.data.toPost()
    }

    /// Your own soft-deleted posts, newest deleted_at first — feeds the Posts
    /// section of "Recently Deleted". Response shape has no `total` field
    /// (unlike `PaginatedResponse`), hence the dedicated inline decoder.
    func fetchDeletedPosts(limit: Int = 30, offset: Int = 0) async throws -> [Post] {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct DeletedPostsResponse: Decodable { let data: [PostDTO] }
        let response = try await client.fetch(
            DeletedPostsResponse.self,
            path: "/posts/deleted",
            method: "GET",
            token: token,
            queryItems: [
                .init(name: "limit",  value: "\(limit)"),
                .init(name: "offset", value: "\(offset)"),
            ]
        )
        return response.data.map { $0.toPost() }
    }

    /// Restore a soft-deleted comment. Note: authorization here is the
    /// COMMENT's own author, not the post's author — different from
    /// `restorePost` above, per the backend's restore-comment endpoint.
    func restoreComment(postId: String, commentId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct RestoreCommentResponse: Decodable {
            let data: CommentDTO
            let commentCount: Int
            enum CodingKeys: String, CodingKey {
                case data
                case commentCount = "comment_count"
            }
        }
        _ = try await client.fetch(
            RestoreCommentResponse.self,
            path: "/posts/\(postId)/comments/\(commentId)/restore",
            method: "POST",
            token: token
        )
    }

    /// Edit the content of your own comment. Note: authorization here is the
    /// COMMENT's own author only — NOT the post's author (unlike delete,
    /// which also allows the post owner to moderate) — per the backend's
    /// edit-comment endpoint. 403 if you're not the comment's author, 404 if
    /// it doesn't exist or is soft-deleted.
    func updateComment(postId: String, commentId: String, content: String) async throws -> CommentDTO {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct UpdateCommentResponse: Decodable { let data: CommentDTO }
        let bodyData = try? JSONSerialization.data(withJSONObject: ["content": content])
        let response = try await client.fetch(
            UpdateCommentResponse.self,
            path: "/posts/\(postId)/comments/\(commentId)",
            method: "PATCH",
            token: token,
            bodyData: bodyData
        )
        return response.data
    }

    /// Posts a comment — or a reply when `parentCommentId` is set — and returns
    /// the created comment. `POST /posts/:id/comments` → 201 `{ data: CommentDTO }`.
    func addComment(postId: String, content: String, parentCommentId: String? = nil) async throws -> CommentDTO {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct AddCommentResponse: Decodable { let data: CommentDTO }
        var body: [String: Any] = ["content": content]
        if let parentCommentId { body["parent_comment_id"] = parentCommentId }
        let response = try await client.fetch(
            AddCommentResponse.self,
            path: "/posts/\(postId)/comments",
            method: "POST",
            token: token,
            bodyData: try? JSONSerialization.data(withJSONObject: body)
        )
        return response.data
    }

    /// Your own soft-deleted comments across all posts, newest deleted_at
    /// first — feeds the Comments section of "Recently Deleted".
    func fetchDeletedComments(limit: Int = 30, offset: Int = 0) async throws -> [DeletedComment] {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct DeletedCommentsResponse: Decodable { let data: [DeletedComment] }
        let response = try await client.fetch(
            DeletedCommentsResponse.self,
            path: "/posts/comments/deleted",
            method: "GET",
            token: token,
            queryItems: [
                .init(name: "limit",  value: "\(limit)"),
                .init(name: "offset", value: "\(offset)"),
            ]
        )
        return response.data
    }

    /// Hides a post from your own feed (persisted server-side; someone else's post)
    func hidePost(postId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct HideResponse: Decodable { let hidden: Bool }
        _ = try await client.fetch(
            HideResponse.self,
            path: "/posts/\(postId)/hide",
            method: "POST",
            token: token
        )
    }

    /// Un-hides a post previously hidden with `hidePost` — backs the "Undo" on
    /// the hide toast (`DELETE /posts/:id/hide`, mirrors `hidePost`).
    func unhidePost(postId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct HideResponse: Decodable { let hidden: Bool }
        _ = try await client.fetch(
            HideResponse.self,
            path: "/posts/\(postId)/hide",
            method: "DELETE",
            token: token
        )
    }

    /// Toggles the current user's like on a post; returns the server's
    /// authoritative liked state + count so the caller can reconcile.
    func toggleLike(postId: String) async throws -> LikeResponse {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        return try await client.fetch(
            LikeResponse.self,
            path: "/posts/\(postId)/like",
            method: "POST",
            token: token
        )
    }

    /// Saves (bookmarks) a post to view again later.
    func savePost(postId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct SaveResponse: Decodable { let saved: Bool }
        _ = try await client.fetch(
            SaveResponse.self,
            path: "/posts/\(postId)/save",
            method: "POST",
            token: token
        )
    }

    /// Unsaves a previously bookmarked post.
    func unsavePost(postId: String) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct SaveResponse: Decodable { let saved: Bool }
        _ = try await client.fetch(
            SaveResponse.self,
            path: "/posts/\(postId)/save",
            method: "DELETE",
            token: token
        )
    }

    /// This user's saved posts, most recently saved first. Response shape
    /// mirrors fetchDeletedPosts's own dedicated inline decoder (no `total`
    /// field, unlike `PaginatedResponse`). No pagination UI for v1 — a single
    /// fetch covers the whole list.
    func fetchSavedPosts(limit: Int = 30, offset: Int = 0) async throws -> [Post] {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        struct SavedPostsResponse: Decodable { let data: [PostDTO] }
        let response = try await client.fetch(
            SavedPostsResponse.self,
            path: "/posts/saved",
            method: "GET",
            token: token,
            queryItems: [
                .init(name: "limit",  value: "\(limit)"),
                .init(name: "offset", value: "\(offset)"),
            ]
        )
        return response.data.map { $0.toPost() }
    }

    /// Reports a post for a violation (spam, harassment, etc.).
    /// The backend endpoint /posts/:id/report is shared between community posts and
    /// regular Feed posts; the service matches the post's `community_id` against the
    /// `communityId` sent up using strict equality, so `communityId: null` must be sent
    /// explicitly (not omitted) to match Feed posts — which always have community_id =
    /// NULL in the DB.
    func reportPost(postId: String, reason: ReportReason, detail: String? = nil) async throws {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }
        var body: [String: Any] = ["reason": reason.rawValue, "communityId": NSNull()]
        if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["detail"] = detail
        }
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        struct Empty: Decodable {}
        _ = try await client.fetch(
            Empty.self,
            path: "/posts/\(postId)/report",
            method: "POST",
            token: token,
            bodyData: bodyData
        )
    }

    /// Updates a post's content, privacy, and images; returns the updated Post
    func updatePost(
        postId: String,
        content: String,
        privacy: PostPrivacy,
        imageUrl: String? = nil,
        imageUrls: [String] = [],
        linkUrl: String? = nil,
        articleTitle: String? = nil
    ) async throws -> Post {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }

        var body: [String: Any] = [
            "content": content,
            "privacy": privacy.rawValue,
        ]
        if let img = imageUrl     { body["image_url"]     = img }
        if !imageUrls.isEmpty     { body["image_urls"]    = imageUrls }
        if let lnk = linkUrl      { body["link_url"]      = lnk }
        if let ttl = articleTitle { body["article_title"] = ttl }

        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        struct UpdateResponse: Decodable { let data: PostDTO }
        let response = try await client.fetch(
            UpdateResponse.self,
            path: "/posts/\(postId)",
            method: "PATCH",
            token: token,
            bodyData: bodyData
        )
        return response.data.toPost()
    }

    func uploadImage(_ imageData: Data) async throws -> String? {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return nil }

        // No GPS/camera/date metadata leaves the phone.
        let clean = try await MediaSanitizer.cleanImage(imageData)

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"photo.\(clean.fileExtension)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(clean.mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(clean.data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: APIConfig.baseURL + "/uploads") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // The response also has a numeric field (size), so it must be decoded with a
        // struct, not [String: String] — previously a decode failure dropped the image.
        struct UploadResponse: Decodable { let url: String }

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONDecoder().decode(UploadResponse.self, from: responseData) else {
            return nil
        }

        return "\(APIConfig.serverBase)\(parsed.url)"
    }

    /// Uploads a video post (mp4/mov) through the same /uploads endpoint; returns an absolute URL
    func uploadVideo(fileURL: URL) async throws -> String? {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return nil }
        // No GPS/camera/date metadata leaves the phone.
        let clean = try await MediaSanitizer.cleanVideo(at: fileURL)
        defer { try? FileManager.default.removeItem(at: clean.url) }
        guard let videoData = try? Data(contentsOf: clean.url) else { return nil }

        let mime = clean.mimeType
        let filename = "video.\(clean.url.pathExtension)"

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(videoData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: APIConfig.baseURL + "/uploads") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        struct UploadResponse: Decodable { let url: String }

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONDecoder().decode(UploadResponse.self, from: responseData) else {
            return nil
        }

        return "\(APIConfig.serverBase)\(parsed.url)"
    }
}
