import Foundation

extension Notification.Name {
    static let postDeleted = Notification.Name("postDeleted")
    static let postUpdated = Notification.Name("postUpdated")
}

enum PostPrivacy: String, CaseIterable {
    case publicAll  = "public"
    case friends    = "friends"
    case onlyMe     = "only_me"

    var label: String {
        switch self {
        case .publicAll: return Bundle.app.loc("Public")
        case .friends:   return Bundle.app.loc("Friends")
        case .onlyMe:    return Bundle.app.loc("Only me")
        }
    }

    var icon: String {
        switch self {
        case .publicAll: return "globe"
        case .friends:   return "person.2.fill"
        case .onlyMe:    return "lock.fill"
        }
    }

    var description: String {
        switch self {
        case .publicAll: return Bundle.app.loc("Everyone can see")
        case .friends:   return Bundle.app.loc("Only your friends")
        case .onlyMe:    return Bundle.app.loc("Only you can see")
        }
    }

    /// Nhãn phụ thuộc mode: mức "friends" gọi là "Bạn bè" ở chế độ bạn bè,
    /// "Kết nối" ở chế độ công việc. Các mức khác giữ nguyên.
    func label(for mode: AppMode) -> String {
        if self == .friends {
            return mode == .hobby ? Bundle.app.loc("Friends") : Bundle.app.loc("Connections")
        }
        return label
    }

    /// Mô tả phụ thuộc mode, đồng bộ cách gọi "bạn bè"/"kết nối".
    func description(for mode: AppMode) -> String {
        if self == .friends {
            return mode == .hobby
                ? Bundle.app.loc("Only your friends")
                : Bundle.app.loc("Only your connections")
        }
        return description
    }
}

/// Bản rút gọn của bài gốc được nhúng trong một bài share
struct SharedPostPreview {
    let id: String
    let author: UserProfile
    let content: String
    let imageUrl: String?
    var imageUrls: [String] = []
    let linkUrl: String?
    let articleTitle: String?
    let timestamp: Date

    /// Ảnh để render lưới: ưu tiên mảng mới, fallback ảnh đơn của bài cũ
    var displayImageUrls: [String] {
        if !imageUrls.isEmpty { return imageUrls }
        if linkUrl == nil, let imageUrl { return [imageUrl] }
        return []
    }
}

struct Post: Identifiable {
    let id: String
    let author: UserProfile
    let content: String
    let timestamp: Date
    let mode: AppMode
    var privacy: PostPrivacy = .publicAll
    var linkUrl: String?         // URL gốc cho link preview
    var imageUrl: String?        // thumbnail URL (từ link preview hoặc upload) — legacy, = ảnh đầu
    var imageUrls: [String] = [] // mảng ảnh upload, có thứ tự
    var likeCount: Int
    var commentCount: Int
    var shareCount: Int
    var isLiked: Bool = false
    var articleTitle: String?
    var tags: [String]
    /// non-nil = đây là bài share; sharedPost nil khi bài gốc đã bị xóa
    var sharedPostId: String? = nil
    var sharedPost: SharedPostPreview? = nil

    /// Ảnh để render lưới: ưu tiên mảng mới, fallback ảnh đơn của bài cũ.
    /// Bài có link preview không tính (ảnh đó thuộc link card).
    var displayImageUrls: [String] {
        if !imageUrls.isEmpty { return imageUrls }
        if linkUrl == nil, let imageUrl { return [imageUrl] }
        return []
    }
}
