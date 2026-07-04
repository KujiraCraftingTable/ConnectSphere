import Foundation

extension Notification.Name {
    static let postDeleted = Notification.Name("postDeleted")
    static let postUpdated = Notification.Name("postUpdated")
}

enum PostPrivacy: String, CaseIterable {
    case publicAll  = "public"
    case friends    = "friends"
    case specific   = "specific"
    case onlyMe     = "only_me"

    var label: String {
        switch self {
        case .publicAll: return "Công khai"
        case .friends:   return "Bạn bè"
        case .specific:  return "Bạn bè cụ thể"
        case .onlyMe:    return "Chỉ mình tôi"
        }
    }

    var icon: String {
        switch self {
        case .publicAll: return "globe"
        case .friends:   return "person.2.fill"
        case .specific:  return "person.badge.shield.checkmark"
        case .onlyMe:    return "lock.fill"
        }
    }

    var description: String {
        switch self {
        case .publicAll: return "Tất cả mọi người đều thấy"
        case .friends:   return "Chỉ bạn bè của bạn"
        case .specific:  return "Chọn bạn bè cụ thể"
        case .onlyMe:    return "Chỉ bạn mới thấy"
        }
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
    var imagePlaceholderColor: String?
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
