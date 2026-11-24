import Foundation

/// What the assistant matcher resolved a user's free-text request to.
///
/// Two categories:
/// - *Executable*: a local, instantly-reversible action performed immediately
///   (no confirmation tap), except `logout` which is disruptive enough to
///   warrant an inline Yes/No confirmation instead of auto-executing.
/// - *Guidance*: something the assistant can't perform itself (network-backed
///   and/or has real consequences, block/unblock, delete account, mute a
///   conversation, rename a group, etc.). It explains where the feature
///   lives instead, with an optional "Take me there" navigation button.
enum AssistantIntent: Equatable {
    // MARK: Executable
    case setTheme(AppearanceMode)
    case setLanguage(AppLanguage)
    case switchMode(AppMode)
    case navigateTab(Int)
    case openSettings
    case logout
    /// A safe setting, read with its value by `AssistantSettingParser`.
    case changeSetting(AssistantSettingChange)

    // MARK: Guidance-only
    case howTo(topic: AssistantGuidanceTopic)

    // MARK: Fallback
    case unknown

    /// True for the actions the assistant performs immediately with no
    /// confirmation step, used by `AssistantMatcher` to gate a negation
    /// check (a phrase that *rejects* an action shouldn't silently trigger
    /// it). `logout` is included even though it has its own separate Yes/No
    /// bubble, the check is purely defensive there, never harmful.
    var isInstantlyExecuted: Bool {
        switch self {
        case .setTheme, .setLanguage, .switchMode, .navigateTab, .openSettings, .logout, .changeSetting:
            return true
        case .howTo, .unknown:
            return false
        }
    }
}
