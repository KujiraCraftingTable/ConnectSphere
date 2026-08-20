import Foundation

/// Single access point for all post-related API calls.
/// ViewModels use this instead of calling NetworkClient directly.
struct PostRepository {
    private let client = NetworkClient.shared

    func fetchPosts(mode: AppMode, connectionsOnly: Bool = false, limit: Int = 20, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(
                mode: mode.rawValue,
                filter: connectionsOnly ? "connections" : nil,
                limit: limit,
                offset: offset
            )
        )
        return response.data.map { $0.toPost() }
    }

    /// Personalized newsfeed (recommendations) — phân trang bằng keyset cursor.
    /// Trả về (posts, nextCursor); nextCursor = nil nghĩa là hết trang.
    func fetchRecommendedFeed(mode: AppMode, cursor: String?, limit: Int = 20) async throws -> (posts: [Post], nextCursor: String?) {
        let response = try await client.fetch(
            CursorResponse<PostDTO>.self,
            from: .recommendedFeed(mode: mode.rawValue, cursor: cursor, limit: limit)
        )
        return (response.data.map { $0.toPost() }, response.nextCursor)
    }

    /// Lấy một bài viết theo id (dùng cho màn hình mở từ notification)
    func fetchPost(id: String) async throws -> Post {
        let response = try await client.fetch(
            SingleResponse<PostDTO>.self,
            from: .getPost(id: id)
        )
        return response.data.toPost()
    }

    /// Bài viết theo hashtag (browse tag)
    func fetchPostsByTag(_ tag: String, limit: Int = 50, offset: Int = 0) async throws -> [Post] {
        let response = try await client.fetch(
            PaginatedResponse<PostDTO>.self,
            from: .listPosts(tag: tag, limit: limit, offset: offset)
        )
        return response.data.map { $0.toPost() }
    }

    /// Share/repost một bài viết; trả về bài share mới
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

    /// Creates a post and returns the new post's ID.
    /// Backend lấy author từ JWT nên không gửi author_id nữa.
    func createPost(
        content: String,
        mode: AppMode,
        privacy: PostPrivacy,
        imageUrl: String? = nil,
        imageUrls: [String] = [],
        linkUrl: String? = nil,
        articleTitle: String? = nil
    ) async throws -> String {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else {
            throw APIError.serverError(statusCode: 401, message: "Not authenticated")
        }

        var body: [String: Any] = [
            "content": content,
            "mode":    mode.rawValue,
            "privacy": privacy.rawValue,
        ]
        if let img = imageUrl      { body["image_url"]     = img }
        if !imageUrls.isEmpty      { body["image_urls"]    = imageUrls }
        if let lnk = linkUrl       { body["link_url"]      = lnk }
        if let ttl = articleTitle  { body["article_title"] = ttl }

        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        struct CreatePostResponse: Decodable { struct PostIdOnly: Decodable { let id: String }; let data: PostIdOnly }
        let response = try await client.fetch(
            CreatePostResponse.self,
            path: "/posts",
            method: "POST",
            token: token,
            bodyData: bodyData
        )
        return response.data.id
    }

    /// Soft-delete bài viết — backend set state = 'deleted', bài sẽ ẩn khỏi feed
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

    /// Ẩn bài viết khỏi feed của riêng mình (persist server-side, bài của người khác)
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

    /// Báo cáo bài viết vi phạm (spam, quấy rối, ...).
    /// Backend endpoint /posts/:id/report được dựng chung cho bài trong community lẫn
    /// bài Feed thường; service so khớp `community_id` của bài với `communityId` gửi lên
    /// bằng strict equality, nên phải gửi tường minh `communityId: null` (không phải bỏ
    /// field) để khớp với bài Feed — vốn luôn có community_id = NULL ở DB.
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

    /// Cập nhật nội dung, privacy, ảnh của bài viết; trả về Post đã được cập nhật
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

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: APIConfig.baseURL + "/uploads") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Response có cả field số (size) nên phải decode bằng struct,
        // không dùng [String: String] — trước đây decode fail làm ảnh bị rớt.
        struct UploadResponse: Decodable { let url: String }

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let parsed = try? JSONDecoder().decode(UploadResponse.self, from: responseData) else {
            return nil
        }

        return "\(APIConfig.serverBase)\(parsed.url)"
    }

    /// Upload video post (mp4/mov) qua cùng endpoint /uploads; trả URL tuyệt đối
    func uploadVideo(fileURL: URL) async throws -> String? {
        guard let token = KeychainHelper.load(forKey: KeychainHelper.tokenKey) else { return nil }
        guard let videoData = try? Data(contentsOf: fileURL) else { return nil }

        let ext = fileURL.pathExtension.lowercased()
        let mime = ext == "mov" ? "video/quicktime" : "video/mp4"
        let filename = "video.\(ext.isEmpty ? "mp4" : ext)"

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
