import Foundation

/// Danh mục endpoint dùng qua NetworkClient.fetch(from:).
/// Danh tính người gọi do backend đọc từ JWT (NetworkClient tự gắn Bearer),
/// nên không endpoint nào nhận viewer/user id từ client nữa.
enum Endpoint {
    case listUsers(mode: String? = nil, search: String? = nil, limit: Int = 20, offset: Int = 0)
    case getUser(id: String, mode: String? = nil)
    case listPosts(mode: String? = nil, authorId: String? = nil, filter: String? = nil, tag: String? = nil, limit: Int = 20, offset: Int = 0)
    case getPost(id: String)
    case recommendedFeed(mode: String, cursor: String? = nil, limit: Int = 20)
    case aiSearch(query: String, mode: String? = nil, radiusKm: Int? = nil)
    case listProvinces
    case listWards(provinceCode: String)
    case analyzePost(content: String, currentMode: String)
    case linkPreview(url: String)
    case listComments(postId: String)
    case searchSuggestions(mode: String?)

    private static let baseURL = APIConfig.baseURL

    /// Per-endpoint timeout. AI search allows up to 90 s for LLM inference.
    var timeoutInterval: TimeInterval {
        switch self {
        case .aiSearch: return 90
        default:        return 30
        }
    }

    var url: URL? {
        var components = URLComponents(string: Self.baseURL + path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url
    }

    var httpMethod: String {
        switch self {
        case .aiSearch, .analyzePost, .linkPreview: return "POST"
        default:                                    return "GET"
        }
    }

    var httpBody: Data? {
        switch self {
        case .aiSearch(let q, let mode, let radiusKm):
            var dict: [String: Any] = ["query": q]
            if let mode     = mode     { dict["mode"]     = mode }
            if let radiusKm = radiusKm { dict["radiusKm"] = radiusKm }
            return try? JSONSerialization.data(withJSONObject: dict)
        case .analyzePost(let content, let mode):
            return try? JSONEncoder().encode(["content": content, "currentMode": mode])
        case .linkPreview(let url):
            return try? JSONEncoder().encode(["url": url])
        default:
            return nil
        }
    }

    private var path: String {
        switch self {
        case .listUsers:                return "/users"
        case .getUser(let id, _):       return "/users/\(id)"
        case .listPosts:                return "/posts"
        case .getPost(let id):          return "/posts/\(id)"
        case .recommendedFeed:          return "/feed/recommendations"
        case .analyzePost:              return "/posts/analyze"
        case .linkPreview:              return "/link-preview"
        case .listComments(let postId): return "/posts/\(postId)/comments"
        case .aiSearch:                 return "/search/ai"
        case .searchSuggestions:        return "/search/suggestions"
        case .listProvinces:            return "/wards/provinces"
        case .listWards:                return "/wards"
        }
    }

    private var queryItems: [URLQueryItem] {
        switch self {
        case .listUsers(let mode, let search, let limit, let offset):
            var items: [URLQueryItem] = [
                .init(name: "limit",  value: "\(limit)"),
                .init(name: "offset", value: "\(offset)"),
            ]
            if let mode   = mode   { items.append(.init(name: "mode",   value: mode)) }
            if let search = search { items.append(.init(name: "search", value: search)) }
            return items

        case .getUser(_, let mode):
            var items: [URLQueryItem] = []
            if let mode { items.append(.init(name: "mode", value: mode)) }
            return items

        case .searchSuggestions(let mode):
            var items: [URLQueryItem] = []
            if let mode { items.append(.init(name: "mode", value: mode)) }
            return items

        case .listWards(let provinceCode):
            return [.init(name: "province_code", value: provinceCode)]

        case .listPosts(let mode, let authorId, let filter, let tag, let limit, let offset):
            var items: [URLQueryItem] = [
                .init(name: "limit",  value: "\(limit)"),
                .init(name: "offset", value: "\(offset)"),
            ]
            if let mode     = mode     { items.append(.init(name: "mode",      value: mode)) }
            if let authorId = authorId { items.append(.init(name: "author_id", value: authorId)) }
            if let filter   = filter   { items.append(.init(name: "filter",    value: filter)) }
            if let tag      = tag      { items.append(.init(name: "tag",       value: tag)) }
            return items

        case .recommendedFeed(let mode, let cursor, let limit):
            var items: [URLQueryItem] = [
                .init(name: "mode",  value: mode),
                .init(name: "limit", value: "\(limit)"),
            ]
            if let cursor = cursor { items.append(.init(name: "cursor", value: cursor)) }
            return items

        default:
            return []
        }
    }
}
