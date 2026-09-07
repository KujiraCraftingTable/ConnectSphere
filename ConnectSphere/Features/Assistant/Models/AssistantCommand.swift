import Foundation

/// One entry in the trigger-phrase registry: an intent plus the phrases that
/// should resolve to it.
struct AssistantCommand {
    let intent: AssistantIntent
    let phrases: [String]
}

/// The trigger-phrase registry — the actual "brain" of the assistant.
///
/// Every executable action and guidance topic pairs with a realistic set of
/// English + Vietnamese phrasings, matched case-insensitively by
/// `AssistantMatcher` regardless of the user's current `appLanguage` (the
/// most forgiving behavior — bilingual app, bilingual input either way).
/// All phrases are lowercase; `AssistantMatcher` lowercases input before
/// comparing.
enum AssistantCommandRegistry {
    static let all: [AssistantCommand] = [

        // MARK: - Theme

        AssistantCommand(intent: .setTheme(.dark), phrases: [
            "dark mode", "turn on dark mode", "switch to dark mode", "switch to dark",
            "enable dark mode", "dark theme", "night mode", "make it dark", "go dark",
            "chế độ tối", "bật chế độ tối", "chuyển sang tối", "chuyển sang chế độ tối",
            "giao diện tối", "chế độ ban đêm", "bật dark mode"
        ]),
        AssistantCommand(intent: .setTheme(.light), phrases: [
            "light mode", "turn on light mode", "switch to light mode", "switch to light",
            "enable light mode", "light theme", "day mode", "make it light", "go light", "bright mode",
            "chế độ sáng", "bật chế độ sáng", "chuyển sang sáng", "chuyển sang chế độ sáng",
            "giao diện sáng", "chế độ ban ngày"
        ]),
        AssistantCommand(intent: .setTheme(.system), phrases: [
            "system theme", "system mode", "match system", "auto theme",
            "use system appearance", "default theme", "automatic mode",
            "chế độ hệ thống", "theo hệ thống", "tự động theo hệ thống",
            "giao diện mặc định", "chế độ tự động"
        ]),

        // MARK: - Language

        AssistantCommand(intent: .setLanguage(.english), phrases: [
            "switch to english", "change language to english", "use english",
            "set language english", "english please", "speak english",
            "chuyển sang tiếng anh", "đổi ngôn ngữ sang tiếng anh", "dùng tiếng anh", "ngôn ngữ tiếng anh"
        ]),
        AssistantCommand(intent: .setLanguage(.vietnamese), phrases: [
            "switch to vietnamese", "change language to vietnamese", "use vietnamese", "set language vietnamese",
            "chuyển sang tiếng việt", "đổi ngôn ngữ sang tiếng việt", "dùng tiếng việt",
            "ngôn ngữ tiếng việt", "nói tiếng việt"
        ]),

        // MARK: - Mode

        AssistantCommand(intent: .switchMode(.work), phrases: [
            "switch to work mode", "switch to work", "go to work mode", "work profile",
            "change to work mode", "work persona",
            "chuyển sang chế độ công việc", "chuyển sang công việc", "chế độ công việc", "hồ sơ công việc"
        ]),
        AssistantCommand(intent: .switchMode(.hobby), phrases: [
            "switch to hobby mode", "switch to hobby", "go to hobby mode", "hobby profile",
            "change to hobby mode", "personal mode", "social mode",
            "chuyển sang chế độ sở thích", "chuyển sang sở thích", "chế độ sở thích",
            "hồ sơ sở thích", "chế độ cá nhân"
        ]),

        // MARK: - Navigate: tabs

        AssistantCommand(intent: .navigateTab(0), phrases: [
            "go home", "take me home", "open home", "go to home", "show my feed", "go to feed", "home page",
            "về trang chủ", "đi đến trang chủ", "mở trang chủ", "về newfeed", "xem bảng tin"
        ]),
        AssistantCommand(intent: .navigateTab(1), phrases: [
            "open search", "go to search", "search page", "find people", "take me to search",
            "mở tìm kiếm", "đi đến tìm kiếm", "tìm kiếm người", "trang tìm kiếm"
        ]),
        AssistantCommand(intent: .navigateTab(2), phrases: [
            "open communities", "go to communities", "show communities", "community page", "take me to communities",
            "mở cộng đồng", "đi đến cộng đồng", "trang cộng đồng", "xem cộng đồng"
        ]),
        AssistantCommand(intent: .navigateTab(3), phrases: [
            "open notifications", "go to notifications", "show notifications", "check notifications",
            "mở thông báo", "đi đến thông báo", "xem thông báo", "kiểm tra thông báo"
        ]),
        AssistantCommand(intent: .navigateTab(4), phrases: [
            "open profile", "go to profile", "show my profile", "my profile", "take me to my profile",
            "mở hồ sơ", "đi đến hồ sơ", "xem hồ sơ của tôi", "hồ sơ của tôi"
        ]),
        AssistantCommand(intent: .openSettings, phrases: [
            "open settings", "go to settings", "show settings", "app settings", "take me to settings",
            "mở cài đặt", "đi đến cài đặt", "xem cài đặt", "cài đặt ứng dụng"
        ]),

        // MARK: - Logout

        AssistantCommand(intent: .logout, phrases: [
            "log out", "logout", "sign out", "log me out", "sign me out",
            "đăng xuất", "thoát tài khoản", "đăng xuất tài khoản"
        ]),

        // MARK: - Guidance

        AssistantCommand(intent: .howTo(topic: .changePassword), phrases: [
            "change my password", "how do i change my password", "reset password", "update password", "change password",
            "forgot my password", "forgot password", "reset it", "reset my password",
            "đổi mật khẩu", "cách đổi mật khẩu", "thay đổi mật khẩu", "cập nhật mật khẩu", "quên mật khẩu"
        ]),
        AssistantCommand(intent: .howTo(topic: .blockUser), phrases: [
            "block someone", "how do i block a user", "block a user", "how to block", "block this person",
            "chặn người dùng", "cách chặn ai đó", "chặn một người", "chặn tài khoản"
        ]),
        AssistantCommand(intent: .howTo(topic: .deleteAccount), phrases: [
            "delete my account", "how do i delete my account", "remove my account", "close my account",
            "xóa tài khoản", "cách xóa tài khoản", "huỷ tài khoản", "xoá tài khoản của tôi"
        ]),
        AssistantCommand(intent: .howTo(topic: .muteConversation), phrases: [
            "mute a conversation", "mute this chat", "how do i mute a chat", "turn off chat notifications", "silence a conversation",
            "tắt thông báo cuộc trò chuyện", "cách tắt thông báo chat", "im lặng cuộc trò chuyện", "tắt tiếng đoạn chat"
        ]),
        AssistantCommand(intent: .howTo(topic: .renameGroup), phrases: [
            "rename a group", "rename this group chat", "change group name", "how do i rename my group",
            "đổi tên nhóm", "cách đổi tên nhóm chat", "thay đổi tên nhóm"
        ]),
        AssistantCommand(intent: .howTo(topic: .editProfile), phrases: [
            "edit my profile", "how do i edit my profile", "update my profile", "change my bio", "change my avatar",
            "change my profile picture", "update my profile picture", "change my photo",
            "chỉnh sửa hồ sơ", "cách sửa hồ sơ", "cập nhật hồ sơ", "đổi ảnh đại diện", "đổi tiểu sử"
        ]),
        AssistantCommand(intent: .howTo(topic: .notificationSounds), phrases: [
            "notification sounds", "turn off message sounds", "how do i change notification sounds", "message sound settings",
            "âm thanh thông báo", "tắt âm thanh tin nhắn", "cách đổi âm thanh thông báo"
        ]),
        AssistantCommand(intent: .howTo(topic: .privacySecurity), phrases: [
            "privacy settings", "privacy and security", "how do i manage my privacy", "security settings",
            "cài đặt quyền riêng tư", "quyền riêng tư và bảo mật", "cài đặt bảo mật"
        ])
    ]
}
