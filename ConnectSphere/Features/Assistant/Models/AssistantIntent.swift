import Foundation

/// What the assistant matcher resolved a user's free-text request to.
///
/// Two categories:
/// - *Executable*: a local, instantly-reversible action performed immediately
///   (no confirmation tap), except `logout` which is disruptive enough to
///   warrant an inline Yes/No confirmation instead of auto-executing.
/// - *Guidance*: something the assistant can't perform itself (network-backed
///   and/or has real consequences — block/unblock, delete account, mute a
///   conversation, rename a group, etc.) — it explains where the feature
///   lives instead, with an optional "Take me there" navigation button.
enum AssistantIntent: Equatable {
    // MARK: Executable
    case setTheme(AppearanceMode)
    case setLanguage(AppLanguage)
    case switchMode(AppMode)
    case navigateTab(Int)
    case openSettings
    case logout

    // MARK: Guidance-only
    case howTo(topic: AssistantGuidanceTopic)

    // MARK: Fallback
    case unknown

    /// True for the actions the assistant performs immediately with no
    /// confirmation step — used by `AssistantMatcher` to gate a negation
    /// check (a phrase that *rejects* an action shouldn't silently trigger
    /// it). `logout` is included even though it has its own separate Yes/No
    /// bubble — the check is purely defensive there, never harmful.
    var isInstantlyExecuted: Bool {
        switch self {
        case .setTheme, .setLanguage, .switchMode, .navigateTab, .openSettings, .logout:
            return true
        case .howTo, .unknown:
            return false
        }
    }
}

/// A guidance-only topic — something the assistant explains rather than
/// performs. Each carries a localization key for its instructional reply and
/// the best-reachable "Take me there" landing screen (can't deep-link to the
/// exact settings row, so landing on the right screen/tab is the bar here).
enum AssistantGuidanceTopic: String, CaseIterable, Equatable {
    case changePassword
    case blockUser
    case deleteAccount
    case muteConversation
    case renameGroup
    case editProfile
    case notificationSounds
    case privacySecurity

    /// Localization key for this topic's instructional reply. Text describes
    /// the real navigation path (verified by reading the actual Settings /
    /// Chat Settings screens), not a guessed one.
    var messageKey: String {
        switch self {
        case .changePassword:
            return "You can change your password from Settings → Privacy & Security → Change password."
        case .blockUser:
            return "To block someone, open their profile and choose Block from the menu. You can manage or unblock people anytime from Settings → Privacy & Security → Blocked users."
        case .deleteAccount:
            return "You can delete your account from Settings → Privacy & Security → Delete account. This can't be undone."
        case .muteConversation:
            return "Open a conversation from Home → Messages, tap the chat name at the top, then turn on Mute notifications."
        case .renameGroup:
            return "Open the group chat from Home → Messages, tap the group name at the top, then choose Rename group."
        case .editProfile:
            return "You can edit your profile from the Profile tab — tap Edit profile — or from Settings → Edit profile."
        case .notificationSounds:
            return "Manage notification sounds from Settings → Notifications → Message sounds."
        case .privacySecurity:
            return "Manage privacy and security options from Settings → Privacy & Security."
        }
    }

    /// Landing target for this topic's "Take me there" button — lands exactly
    /// on the screen (or screen + opened sheet) the instructional text above
    /// names, not just the top-level Settings list.
    var navigationTarget: AssistantNavigationTarget {
        switch self {
        case .changePassword:
            return .changePassword
        case .deleteAccount:
            return .deleteAccount
        case .blockUser:
            return .blockedUsers   // the manage/unblock screen the text names
        case .notificationSounds:
            return .notificationSettings
        case .privacySecurity:
            return .privacySecurity
        case .editProfile:
            return .editProfile
        case .muteConversation, .renameGroup:
            // No deeper screen exists — both require a specific conversation
            // the user hasn't picked yet, which is exactly what the
            // instructional text above says to do first.
            return .tab(0)   // Home — where the Messages entry point lives
        }
    }
}
