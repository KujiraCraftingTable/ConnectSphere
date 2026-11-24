import Foundation

enum AssistantChatFilter { case all, groups }

/// Everything the assistant can explain and take you to, kept in one place:
/// each topic's reply, the phrases that ask for it and the screen it opens.
/// The reply text is also the localization key, and `AssistantRegistryTests`
/// checks every topic has both translations, phrases that resolve back to it,
/// and a real destination, so the three can't drift apart again.
///
/// Paths in the replies follow the screens as they are: Privacy & Security,
/// Username, Email, Activity log and deleting all sit under Manage account.
enum AssistantGuidanceTopic: String, CaseIterable, Equatable {
    // Account and security
    case manageAccount
    case changeUsername
    case changeEmail
    case changePassword
    case twoFactor
    case accountStatus
    case activityLog
    case downloadData
    case deleteAccount
    // Privacy
    case privacySecurity
    case friendRequests
    case peopleYouMayKnow
    case activityTracking
    case lockProfile
    case otherProfileLink
    case blockUser
    case hiddenContacts
    // Content
    case editProfile
    case mutedWords
    case drafts
    case savedPosts
    case recentlyDeleted
    // Look and notifications
    case themeColor
    case appIcon
    case translations
    case searchRadius
    case notificationSounds
    case aiSuggestions
    // Chats
    case muteConversation
    case renameGroup
    case chatTheme
    case chatNickname
    // How the app works
    case appModes
    case postPrivacy
    case aiSearch
    case communities
    case marketplace
    case deposits
    case reviews
    case becomeHR
    case reportPost
    case stories
    case assistantHelp

    /// The rows screens tag with `assistantHighlightRow`; a target may only
    /// highlight one of these.
    static let highlightableRows: Set<AssistantGuidanceTopic> = [
        .changeEmail, .deleteAccount, .twoFactor, .friendRequests, .peopleYouMayKnow,
        .activityTracking, .lockProfile, .otherProfileLink, .themeColor, .appIcon,
        .translations, .searchRadius, .notificationSounds, .aiSuggestions,
    ]

    /// Said instead of `changePassword`'s reply to someone who signed up with
    /// Google and has no password yet, since the row reads "Set password".
    static let setPasswordMessageKey =
        "You can set a password in Settings → Manage account → Privacy & Security → Set password, so you can also sign in with your username."

    /// The reply, which is also its localization key.
    var messageKey: String {
        switch self {
        case .manageAccount:
            return "Your username, email, privacy, activity log, data download and deleting your account are in Settings → Manage account."
        case .changeUsername:
            return "Change your username in Settings → Manage account → Username. You can change it once every 6 months."
        case .changeEmail:
            return "Add or change your email in Settings → Manage account → Email. We send a code to check it's yours."
        case .changePassword:
            return "You can change your password in Settings → Manage account → Privacy & Security → Change password."
        case .twoFactor:
            return "Turn two-factor authentication on or off in Settings → Manage account → Privacy & Security → Two-factor authentication. You confirm it with a code sent to your email."
        case .accountStatus:
            return "See any warnings or bans on your profiles in Settings → Manage account → Account status."
        case .activityLog:
            return "See what you've done recently in Settings → Manage account → Activity log."
        case .downloadData:
            return "Download a copy of your data in Settings → Manage account → Download my data."
        case .deleteAccount:
            return "You can delete your Hobby profile, your Work profile or your whole account in Settings → Manage account → Delete. It needs a code sent to your verified email, and it can't be undone."
        case .privacySecurity:
            return "Manage privacy and security options in Settings → Manage account → Privacy & Security."
        case .friendRequests:
            return "Choose whether people can send you friend requests in Settings → Manage account → Privacy & Security → Allow friend requests."
        case .peopleYouMayKnow:
            return "Choose whether you're suggested to others in Settings → Manage account → Privacy & Security → Show me in People you may know."
        case .activityTracking:
            return "Choose whether your activity personalises your feed and search in Settings → Manage account → Privacy & Security → Personalise with my activity."
        case .lockProfile:
            return "Lock your profile so only friends or connections see your posts and lists in Settings → Manage account → Privacy & Security → Lock my profile."
        case .otherProfileLink:
            return "Choose whether your profile links to your other profile in Settings → Manage account → Privacy & Security → Show a link to my other profile."
        case .blockUser:
            return "To block someone, open their profile and choose Block from the menu. You can see and unblock people in Settings → Manage account → Privacy & Security → Blocked users."
        case .hiddenContacts:
            return "People you hid from the top of Messages are in Settings → Manage account → Privacy & Security → Hidden contacts."
        case .editProfile:
            return "You can edit your profile from the Profile tab: tap Edit profile. It's also in Settings → Manage account → Edit profile."
        case .mutedWords:
            return "Hide posts with certain words in Settings → Muted words."
        case .drafts:
            return "Your drafts and scheduled posts are in Settings → Drafts & scheduled."
        case .savedPosts:
            return "Posts you saved are in Settings → Saved."
        case .recentlyDeleted:
            return "Posts you delete stay in Settings → Recently Deleted for 30 days, and you can restore them there."
        case .themeColor:
            return "Pick your theme colour in Settings → App theme → Theme color. Hobby and Work mode each have their own."
        case .appIcon:
            return "Change the app icon in Settings → App theme → App icon."
        case .translations:
            return "Choose how translated posts show in Settings → Language → Translations."
        case .searchRadius:
            return "Set how far from your ward search looks in Settings → Search → Search radius."
        case .notificationSounds:
            return "Turn message sounds on or off in Settings → Notifications → Message sounds."
        case .aiSuggestions:
            return "Turn AI post suggestions on or off in Settings → Notifications → AI post suggestions."
        case .muteConversation:
            return "Open a conversation from Home → Messages, tap the chat name at the top, then turn on Mute notifications."
        case .renameGroup:
            return "Open the group chat from Home → Messages, tap the group name at the top, then choose Rename group."
        case .chatTheme:
            return "Open a conversation from Home → Messages, tap the chat name at the top, then choose Chat theme."
        case .chatNickname:
            return "Open a conversation from Home → Messages, tap the chat name at the top, then choose Nickname. Both of you see it."
        case .appModes:
            return "Every account has two modes, Hobby and Work. Each has its own profile, feed and connections, and posts stay in the mode they were made in. Switch between them at the top of Home."
        case .postPrivacy:
            return "You choose who can see each post when you write it. To keep your profile posts and lists to friends or connections only, lock your profile in Settings → Manage account → Privacy & Security → Lock my profile."
        case .aiSearch:
            return "AI search finds people and posts from a plain sentence, like \"people who play badminton in Thu Duc\". Open the Search tab and type what you're looking for."
        case .communities:
            return "Communities are groups around a shared interest, in Hobby mode only. Find, join or create one from the Communities tab."
        case .marketplace:
            return "The Marketplace is inside Communities, in Hobby mode. One listing can hold 1–20 items, and your own listings are in Settings → Marketplace."
        case .deposits:
            return "When a buyer pays a deposit, the seller records it on the listing, which holds those units for them. Once it's delivered, the seller confirms the deposit as sold. Sales are final."
        case .reviews:
            return "After a confirmed sale, the buyer gets a review card for 3 days to give 0–5 stars and a comment. Sellers with an average of 4.6 or more over at least 50 reviews get a Legit badge."
        case .becomeHR:
            return "Only verified HR can post jobs. In Work mode, open Settings → Become a verified HR. You need a company email, the tax code, the website and the business registration PDF, and the app team checks them by hand."
        case .reportPost:
            return "To report a post, tap ••• on it and choose Report post. Reports go to the app team, who can remove it or restrict the account."
        case .stories:
            return "Add a story from Your story at the top of Home. Keep stories on your profile as highlights."
        case .assistantHelp:
            return "I can switch your theme, language or mode, take you to any setting, and answer questions about how the app works. Try \"turn on 2FA\" or \"where are my drafts\"."
        }
    }

    /// Which chats the assistant lists for a topic done inside one chat;
    /// nil for everything else.
    var chatPicker: AssistantChatFilter? {
        switch self {
        case .renameGroup: return .groups
        case .muteConversation, .chatTheme, .chatNickname: return .all
        default: return nil
        }
    }

    /// Short name for a suggestion button.
    var titleKey: String {
        switch self {
        case .manageAccount:      return "Manage account"
        case .changeUsername:     return "Change username"
        case .changeEmail:        return "Change email"
        case .changePassword:     return "Change password"
        case .twoFactor:          return "Two-factor authentication"
        case .accountStatus:      return "Account status"
        case .activityLog:        return "Activity log"
        case .downloadData:       return "Download my data"
        case .deleteAccount:      return "Delete account"
        case .privacySecurity:    return "Privacy & Security"
        case .friendRequests:     return "Allow friend requests"
        case .peopleYouMayKnow:   return "People you may know"
        case .activityTracking:   return "Personalise with my activity"
        case .lockProfile:        return "Lock my profile"
        case .otherProfileLink:   return "Link to my other profile"
        case .blockUser:          return "Blocked users"
        case .hiddenContacts:     return "Hidden contacts"
        case .editProfile:        return "Edit profile"
        case .mutedWords:         return "Muted words"
        case .drafts:             return "Drafts & scheduled"
        case .savedPosts:         return "Saved"
        case .recentlyDeleted:    return "Recently Deleted"
        case .themeColor:         return "Theme color"
        case .appIcon:            return "App icon"
        case .translations:       return "Translations"
        case .searchRadius:       return "Search radius"
        case .notificationSounds: return "Message sounds"
        case .aiSuggestions:      return "AI post suggestions"
        case .muteConversation:   return "Mute a conversation"
        case .renameGroup:        return "Rename a group"
        case .chatTheme:          return "Chat theme"
        case .chatNickname:       return "Nickname"
        case .appModes:           return "Hobby and Work modes"
        case .postPrivacy:        return "Who can see my posts"
        case .aiSearch:           return "AI search"
        case .communities:        return "Communities"
        case .marketplace:        return "Marketplace"
        case .deposits:           return "Deposits and sales"
        case .reviews:            return "Seller reviews"
        case .becomeHR:           return "Become a verified HR"
        case .reportPost:         return "Report post"
        case .stories:            return "Stories and highlights"
        case .assistantHelp:      return "What I can do"
        }
    }

    /// Where "Take me there" goes: the screen the reply names, with the row
    /// highlighted when the setting is one row among many.
    var navigationTarget: AssistantNavigationTarget? {
        let account: [ProfileRoute] = [.settings, .manageAccount]
        let privacy = account + [.privacySecurity]
        switch self {
        case .manageAccount:      return .profile(account)
        case .changeUsername:     return .profile(account + [.changeUsername])
        case .changeEmail:        return .profile(account, highlight: .changeEmail)
        case .changePassword:     return .profile(privacy, sheet: .changePassword)
        case .twoFactor:          return .profile(privacy, highlight: .twoFactor)
        case .accountStatus:      return .profile(account + [.accountStatus])
        case .activityLog:        return .profile(account + [.activityLog])
        case .downloadData:       return .profile(account + [.dataExport])
        case .deleteAccount:      return .profile(account, highlight: .deleteAccount)
        case .privacySecurity:    return .profile(privacy)
        case .friendRequests:     return .profile(privacy, highlight: .friendRequests)
        case .peopleYouMayKnow:   return .profile(privacy, highlight: .peopleYouMayKnow)
        case .activityTracking:   return .profile(privacy, highlight: .activityTracking)
        case .lockProfile:        return .profile(privacy, highlight: .lockProfile)
        case .otherProfileLink:   return .profile(privacy, highlight: .otherProfileLink)
        case .blockUser:          return .profile(privacy + [.blockedUsers])
        case .hiddenContacts:     return .profile(privacy + [.hiddenContacts])
        case .editProfile:        return .profile([], sheet: .editProfile)
        case .mutedWords:         return .profile([.settings, .mutedWords])
        case .drafts:             return .profile([.settings, .drafts])
        case .savedPosts:         return .profile([.settings, .saved])
        case .recentlyDeleted:    return .profile([.settings, .recentlyDeleted])
        case .themeColor:         return .profile([.settings], highlight: .themeColor)
        case .appIcon:            return .profile([.settings], highlight: .appIcon)
        case .translations:       return .profile([.settings], highlight: .translations)
        case .searchRadius:       return .profile([.settings], highlight: .searchRadius)
        case .notificationSounds: return .profile([.settings, .notificationSettings], highlight: .notificationSounds)
        case .aiSuggestions:      return .profile([.settings, .notificationSettings], highlight: .aiSuggestions)
        case .muteConversation, .renameGroup, .chatTheme, .chatNickname:
            // These need a chat picked first (see `chatPicker`); Home, where
            // Messages is, if there's none to pick.
            return .tab(0)
        case .appModes, .stories: return .tab(0)
        case .postPrivacy:        return .profile(privacy, highlight: .lockProfile)
        case .aiSearch:           return .tab(1)
        case .communities, .marketplace, .deposits: return .tab(2)
        case .becomeHR:           return .profile([.settings])
        case .reviews, .reportPost, .assistantHelp: return nil
        }
    }

    /// English and Vietnamese ways of asking. Lowercase; the matcher picks
    /// the longest phrase found, so a specific phrase here beats a vaguer one
    /// on another topic.
    var phrases: [String] {
        switch self {
        case .manageAccount:
            return ["manage account", "manage my account", "account settings", "my account settings",
                    "quản lý tài khoản", "cài đặt tài khoản"]
        case .changeUsername:
            return ["change my username", "change username", "change my user name", "edit my username",
                    "how do i change my username", "rename my account",
                    "đổi tên người dùng", "thay đổi tên người dùng", "đổi username"]
        case .changeEmail:
            return ["change my email", "change email", "add an email", "add my email", "update my email",
                    "verify my email", "email address",
                    "đổi email", "thay đổi email", "thêm email", "xác minh email"]
        case .changePassword:
            return ["change my password", "how do i change my password", "reset password", "update password",
                    "change password", "forgot my password", "forgot password", "reset it", "reset my password",
                    "set a password", "new password", "set password",
                    "đổi mật khẩu", "cách đổi mật khẩu", "thay đổi mật khẩu", "cập nhật mật khẩu", "quên mật khẩu"]
        case .twoFactor:
            return ["two factor", "two-factor authentication", "2fa", "two step verification",
                    "turn on 2fa", "turn off 2fa",
                    "xác thực hai lớp", "bảo mật hai lớp", "xác minh hai bước"]
        case .accountStatus:
            return ["account status", "am i banned", "my warnings", "why am i banned", "strikes on my account",
                    "trạng thái tài khoản", "tài khoản bị khoá", "cảnh cáo tài khoản"]
        case .activityLog:
            return ["activity log", "my activity log", "what have i done", "my recent activity",
                    "nhật ký hoạt động", "lịch sử hoạt động"]
        case .downloadData:
            return ["download my data", "export my data", "get a copy of my data", "download my information",
                    "tải dữ liệu của tôi", "xuất dữ liệu", "tải dữ liệu"]
        case .deleteAccount:
            return ["delete my account", "how do i delete my account", "remove my account", "close my account",
                    "delete my hobby profile", "delete my work profile",
                    "xóa tài khoản", "cách xóa tài khoản", "huỷ tài khoản", "xoá tài khoản của tôi", "xoá tài khoản"]
        case .privacySecurity:
            return ["privacy settings", "privacy and security", "how do i manage my privacy", "security settings",
                    "cài đặt quyền riêng tư", "quyền riêng tư và bảo mật", "cài đặt bảo mật"]
        case .friendRequests:
            return ["friend requests", "stop friend requests", "who can send me friend requests",
                    "allow friend requests", "block friend requests",
                    "lời mời kết bạn", "chặn lời mời kết bạn", "cho phép lời mời kết bạn"]
        case .peopleYouMayKnow:
            return ["people you may know", "hide me from suggestions", "stop suggesting me", "suggested to others",
                    "những người bạn có thể biết", "ẩn tôi khỏi gợi ý"]
        case .activityTracking:
            return ["personalise with my activity", "personalize with my activity", "track my activity",
                    "stop tracking me", "activity tracking", "personalised feed", "personalized feed",
                    "cá nhân hoá theo hoạt động", "theo dõi hoạt động"]
        case .lockProfile:
            return ["lock my profile", "lock profile", "make my profile private", "private profile",
                    "unlock my profile",
                    "khoá hồ sơ", "khóa hồ sơ", "hồ sơ riêng tư"]
        case .otherProfileLink:
            return ["link to my other profile", "link my profiles", "show my other profile", "hide my other profile",
                    "liên kết hồ sơ", "liên kết tới hồ sơ"]
        case .blockUser:
            return ["block someone", "how do i block a user", "block a user", "how to block", "block this person",
                    "blocked users", "unblock someone", "unblock a user",
                    "chặn người dùng", "cách chặn ai đó", "chặn một người", "chặn tài khoản",
                    "người đã chặn", "bỏ chặn"]
        case .hiddenContacts:
            return ["hidden contacts", "unhide a contact", "people i hid",
                    "liên hệ đã ẩn", "bỏ ẩn liên hệ"]
        case .editProfile:
            return ["edit my profile", "how do i edit my profile", "update my profile", "change my bio",
                    "change my avatar", "change my profile picture", "update my profile picture", "change my photo",
                    "chỉnh sửa hồ sơ", "cách sửa hồ sơ", "cập nhật hồ sơ", "đổi ảnh đại diện", "đổi tiểu sử"]
        case .mutedWords:
            return ["muted words", "mute a word", "hide posts with words", "mute words",
                    "từ đã ẩn", "ẩn từ", "ẩn bài viết có từ"]
        case .drafts:
            return ["my drafts", "drafts", "scheduled posts", "draft posts",
                    "bản nháp", "bài đã lên lịch"]
        case .savedPosts:
            return ["saved posts", "my saved posts", "posts i saved", "bookmarks", "saved items",
                    "bài viết đã lưu", "bài đã lưu"]
        case .recentlyDeleted:
            return ["recently deleted", "restore a post", "deleted posts", "undelete a post",
                    "mới xoá gần đây", "khôi phục bài viết", "bài viết đã xoá"]
        case .themeColor:
            return ["theme color", "theme colour", "change theme color", "change the color", "app color",
                    "accent color",
                    "màu chủ đề", "đổi màu chủ đề", "đổi màu ứng dụng"]
        case .appIcon:
            return ["app icon", "change the app icon", "change app icon",
                    "biểu tượng ứng dụng", "đổi biểu tượng ứng dụng", "đổi icon"]
        case .translations:
            return ["translations", "translation settings", "translate posts", "auto translate",
                    "bản dịch", "dịch bài viết", "cài đặt dịch"]
        case .searchRadius:
            return ["search radius", "search distance", "how far search looks",
                    "bán kính tìm kiếm", "khoảng cách tìm kiếm"]
        case .notificationSounds:
            return ["notification sounds", "turn off message sounds", "how do i change notification sounds",
                    "message sound settings", "message sounds", "mute sounds", "sounds",
                    "âm thanh thông báo", "tắt âm thanh tin nhắn", "cách đổi âm thanh thông báo", "âm thanh tin nhắn"]
        case .aiSuggestions:
            return ["ai post suggestions", "ai suggestions", "post suggestions",
                    "gợi ý ai cho bài viết", "gợi ý ai"]
        case .muteConversation:
            return ["mute a conversation", "mute this chat", "how do i mute a chat", "turn off chat notifications",
                    "silence a conversation", "mute a chat",
                    "tắt thông báo cuộc trò chuyện", "cách tắt thông báo chat", "im lặng cuộc trò chuyện",
                    "tắt tiếng đoạn chat"]
        case .renameGroup:
            return ["rename a group", "rename this group chat", "change group name", "how do i rename my group",
                    "đổi tên nhóm", "cách đổi tên nhóm chat", "thay đổi tên nhóm"]
        case .chatTheme:
            return ["chat theme", "change chat theme", "conversation theme", "chat colour", "chat color",
                    "giao diện đoạn chat", "đổi giao diện đoạn chat", "màu đoạn chat"]
        case .chatNickname:
            return ["nickname", "set a nickname", "change a nickname", "give someone a nickname",
                    "biệt danh", "đặt biệt danh", "đổi biệt danh"]
        case .appModes:
            return ["hobby and work", "what is hobby mode", "what is work mode", "difference between hobby and work",
                    "two modes", "hobby or work",
                    "sở thích và công việc", "chế độ sở thích là gì", "chế độ công việc là gì", "hai chế độ"]
        case .postPrivacy:
            return ["who can see my posts", "who sees my posts", "post privacy", "hide my posts", "make a post private",
                    "ai xem được bài viết", "ai thấy bài viết", "quyền riêng tư bài viết", "ẩn bài viết"]
        case .aiSearch:
            return ["ai search", "how does search work", "smart search", "search with ai",
                    "tìm kiếm ai", "tìm kiếm thông minh"]
        case .communities:
            return ["what are communities", "join a community", "create a community", "make a community",
                    "tham gia cộng đồng", "tạo cộng đồng", "cộng đồng là gì"]
        case .marketplace:
            return ["marketplace", "sell something", "how do i sell", "sell an item", "my listings", "buy something",
                    "chợ", "bán đồ", "đăng bán", "tin đăng của tôi", "mua đồ"]
        case .deposits:
            return ["deposit", "deposits", "record a deposit", "mark as sold", "confirm a sale",
                    "đặt cọc", "tiền cọc", "xác nhận đã bán", "đánh dấu đã bán"]
        case .reviews:
            return ["reviews", "seller reviews", "leave a review", "review a seller", "legit badge",
                    "đánh giá", "đánh giá người bán", "huy hiệu legit"]
        case .becomeHR:
            return ["post a job", "post jobs", "become hr", "verified hr", "hire someone",
                    "đăng tin tuyển dụng", "trở thành hr", "tuyển dụng"]
        case .reportPost:
            return ["report a post", "report someone", "report a user", "report spam",
                    "báo cáo bài viết", "báo cáo người dùng", "tố cáo"]
        case .stories:
            return ["add a story", "post a story", "highlights", "story highlights",
                    "đăng tin", "thêm tin", "tin nổi bật"]
        case .assistantHelp:
            return ["help", "assistant", "what can the assistant do", "trợ giúp", "bạn làm được gì"]
        }
    }
}
