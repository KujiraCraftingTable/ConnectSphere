import Foundation

struct UserProfile: Identifiable {
    let id: String
    var name: String
    var username: String
    var avatarColor: String
    var avatarUrl: String? = nil
    var coverUrl: String? = nil
    var bio: String
    // Colleague fields
    var jobTitle: String?
    var company: String?
    var skills: [String]
    // Friend fields
    var interests: [String]
    var location: String?
    var gender: String?
    // Trạng thái setup persona theo mode — quyết định user có "tồn tại" ở mode
    // đó không (chưa setup = ẩn khỏi search/feed của mode, switch mode bị chặn
    // bằng form tạo persona)
    var hobbySetup: Bool = false
    var workSetup: Bool = false
    // Field riêng của chính chủ (server chỉ trả trong /auth/me và PATCH /users/me)
    var email: String? = nil
    /// Đã có mật khẩu chưa (tài khoản Google thuần = false) — chọn luồng đổi/đặt mật khẩu
    var hasPassword: Bool = false
    // Tuổi hiển thị — có ở cả public lẫn self view, server null khi dob_visibility = private
    var age: Int? = nil
    // Field riêng của chính chủ (server chỉ trả trong /auth/me và PATCH /users/me),
    // giống email/hasPassword ở trên
    var dob: String? = nil
    var dobVisibility: String? = nil
    // Stats
    var followerCount: Int
    var followingCount: Int
    var postCount: Int
    // Số kết nối accepted theo mode đang xem (backend trả kèm khi fetch profile)
    var connectionCount: Int = 0
    // Số bạn/kết nối chung với người đang xem (backend trả kèm trong search/list)
    var mutualCount: Int = 0
    // AI search score — nil for regular search results
    var score: Double?
}
