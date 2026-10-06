import SwiftUI

/// A section in a static content page, self-translated based on AppLanguage
/// (the content is long, so it isn't placed in .strings).
struct StaticInfoSection: Identifiable {
    let id = UUID()
    let headingEN: String
    let headingVI: String
    let bodyEN: String
    let bodyVI: String

    func heading(for lang: AppLanguage) -> String { lang == .vietnamese ? headingVI : headingEN }
    func body(for lang: AppLanguage) -> String { lang == .vietnamese ? bodyVI : bodyEN }
}

/// Static content page shared by Help / Terms / Privacy.
struct StaticInfoView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    /// Localization key for the title (already present in Localizable.strings)
    let titleKey: String
    let sections: [StaticInfoSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.heading(for: appState.appLanguage))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Text(section.body(for: appState.appLanguage))
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Content for the 3 pages (generic for the course project)

extension StaticInfoView {
    static let helpSections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Two modes",
            headingVI: "Hai chế độ",
            bodyEN: "ConnectSphere has two separate spaces: Hobby mode for friends who share your interests, and Work mode for professional networking. Switch between them any time from the pill at the top of the feed or in Settings — each mode has its own feed, profile details and conversations.",
            bodyVI: "ConnectSphere có hai không gian riêng: chế độ Sở thích để kết bạn cùng đam mê và chế độ Công việc để mở rộng quan hệ nghề nghiệp. Bạn có thể chuyển chế độ bất kỳ lúc nào bằng nút ở đầu bảng tin hoặc trong Cài đặt — mỗi chế độ có bảng tin, hồ sơ và hội thoại riêng."
        ),
        StaticInfoSection(
            headingEN: "Finding people",
            headingVI: "Tìm người phù hợp",
            bodyEN: "Use the Search tab and describe who you want to meet in your own words — the AI reads your description and suggests the best matches with reasons for each. Set a search radius in Settings to only see people nearby.",
            bodyVI: "Vào tab Tìm kiếm và mô tả người bạn muốn gặp bằng lời của bạn — AI sẽ đọc mô tả và gợi ý những người phù hợp nhất kèm lý do. Đặt bán kính tìm kiếm trong Cài đặt nếu chỉ muốn gặp người ở gần."
        ),
        StaticInfoSection(
            headingEN: "Communities & chat",
            headingVI: "Cộng đồng & nhắn tin",
            bodyEN: "Join communities to post, run polls and host events with people who share your interests. Once connected with someone, you can message them directly — long-press a message to unsend it, and tap the chat header for per-conversation settings.",
            bodyVI: "Tham gia cộng đồng để đăng bài, tạo bình chọn và sự kiện với những người cùng sở thích. Khi đã kết nối với ai đó, bạn có thể nhắn tin trực tiếp — nhấn giữ tin nhắn để thu hồi, chạm vào tên ở đầu đoạn chat để mở cài đặt riêng."
        ),
        StaticInfoSection(
            headingEN: "Need help?",
            headingVI: "Cần hỗ trợ?",
            bodyEN: "If something isn't working or you want to report a problem, email kujira.gwer@gmail.com. Screenshots make bugs much easier to track down.",
            bodyVI: "Nếu có gì đó không hoạt động hoặc bạn muốn báo lỗi, hãy gửi email tới kujira.gwer@gmail.com. Đính kèm ảnh chụp màn hình sẽ giúp xử lý nhanh hơn."
        ),
    ]

    static let termsSections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "Acceptance",
            headingVI: "Chấp thuận điều khoản",
            bodyEN: "By creating an account you agree to these terms. ConnectSphere is an academic project built for the COMP1682 course; the service is provided as-is, without uptime or data-durability guarantees.",
            bodyVI: "Khi tạo tài khoản, bạn đồng ý với các điều khoản này. ConnectSphere là sản phẩm học thuật thuộc đồ án COMP1682; dịch vụ được cung cấp nguyên trạng, không cam kết thời gian hoạt động hay độ bền dữ liệu."
        ),
        StaticInfoSection(
            headingEN: "Your conduct",
            headingVI: "Quy tắc ứng xử",
            bodyEN: "Don't post content that is illegal, hateful, sexually explicit or harassing. Don't impersonate others or spam. Community admins and moderators may remove content and members that break these rules, and repeated violations can lead to account suspension.",
            bodyVI: "Không đăng nội dung vi phạm pháp luật, thù ghét, khiêu dâm hay quấy rối. Không mạo danh người khác hoặc spam. Quản trị viên cộng đồng có quyền gỡ nội dung và thành viên vi phạm; tái phạm nhiều lần có thể bị khoá tài khoản."
        ),
        StaticInfoSection(
            headingEN: "Your content",
            headingVI: "Nội dung của bạn",
            bodyEN: "You keep ownership of everything you post. By posting you grant ConnectSphere permission to store and display that content to the audience you chose (public, friends, or only me).",
            bodyVI: "Bạn giữ quyền sở hữu mọi nội dung mình đăng. Khi đăng, bạn cho phép ConnectSphere lưu trữ và hiển thị nội dung đó tới đúng phạm vi bạn chọn (công khai, bạn bè, hoặc chỉ mình tôi)."
        ),
        StaticInfoSection(
            headingEN: "Account",
            headingVI: "Tài khoản",
            bodyEN: "Keep your password safe — you're responsible for activity on your account. To request account removal, contact the address in Help & Support.",
            bodyVI: "Hãy giữ mật khẩu an toàn — bạn chịu trách nhiệm với hoạt động trên tài khoản của mình. Để yêu cầu xoá tài khoản, liên hệ địa chỉ trong mục Trợ giúp & Hỗ trợ."
        ),
    ]

    static let privacySections: [StaticInfoSection] = [
        StaticInfoSection(
            headingEN: "What we collect",
            headingVI: "Dữ liệu thu thập",
            bodyEN: "Your profile (name, bio, interests, skills, ward-level location), the posts, stories, comments and messages you create, and basic usage signals such as likes and views.",
            bodyVI: "Hồ sơ của bạn (tên, giới thiệu, sở thích, kỹ năng, vị trí cấp phường/xã), các bài viết, tin, bình luận, tin nhắn bạn tạo, và tín hiệu sử dụng cơ bản như lượt thích, lượt xem."
        ),
        StaticInfoSection(
            headingEN: "How it's used",
            headingVI: "Cách sử dụng",
            bodyEN: "Profile and post content is converted into AI embeddings so search and the feed can suggest people and posts that genuinely match you. Data is used only inside ConnectSphere and is never sold or shared with third parties.",
            bodyVI: "Nội dung hồ sơ và bài viết được chuyển thành vector AI để tính gợi ý tìm kiếm và bảng tin phù hợp với bạn. Dữ liệu chỉ dùng bên trong ConnectSphere, không bán hay chia sẻ cho bên thứ ba."
        ),
        StaticInfoSection(
            headingEN: "Storage & security",
            headingVI: "Lưu trữ & bảo mật",
            bodyEN: "Passwords are hashed with bcrypt and sign-in tokens are kept in the iOS Keychain. Media and posts are stored on the project server. Google Sign-In is used only to verify your identity.",
            bodyVI: "Mật khẩu được băm bằng bcrypt, token đăng nhập lưu trong Keychain của iOS. Ảnh và bài viết lưu trên máy chủ của dự án. Đăng nhập Google chỉ dùng để xác minh danh tính."
        ),
        StaticInfoSection(
            headingEN: "Your controls",
            headingVI: "Quyền của bạn",
            bodyEN: "You choose each post's audience, can block anyone (they can no longer see or message you), report content in communities, and edit your profile at any time. For data deletion requests, contact the address in Help & Support.",
            bodyVI: "Bạn tự chọn phạm vi mỗi bài đăng, có thể chặn bất kỳ ai (họ không thể xem hay nhắn tin cho bạn), báo cáo nội dung trong cộng đồng và chỉnh sửa hồ sơ bất cứ lúc nào. Muốn xoá dữ liệu, liên hệ địa chỉ trong mục Trợ giúp & Hỗ trợ."
        ),
    ]
}
