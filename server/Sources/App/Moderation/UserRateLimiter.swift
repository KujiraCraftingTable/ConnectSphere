import Vapor

/// Per-account limits on what spammers do in bulk (migration 089's companion):
/// posting, commenting, starting chats with strangers, sending friend requests.
/// The per-IP limiter can't see these — one person has many requests, one
/// network has many people — and WhatsApp's biggest spam signal is exactly
/// this: new accounts sending at high speed. Accounts younger than 48 hours get
/// a quarter of the room.
///
/// Counters live in this server process (like `RateLimitMiddleware`), so a
/// restart resets them and a second server would count separately.
struct UserRateLimiter: Sendable {
    enum Action: String, Sendable {
        case post, comment, newChat, friendRequest
    }

    struct Rule: Equatable, Sendable {
        let max: Int
        let window: TimeInterval
    }

    static let newAccountAge: TimeInterval = 48 * 3600

    static func rule(_ action: Action, isNewAccount: Bool) -> Rule {
        let base: Rule
        switch action {
        case .post: base = Rule(max: 20, window: 3600)
        case .comment: base = Rule(max: 60, window: 3600)
        case .newChat: base = Rule(max: 20, window: 86_400)
        case .friendRequest: base = Rule(max: 30, window: 86_400)
        }
        return isNewAccount ? Rule(max: max(3, base.max / 4), window: base.window) : base
    }

    static func isNewAccount(createdAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) < newAccountAge
    }

    static let shared = UserRateLimiter()
    private let store = RateLimitMiddleware.Store()

    /// Counts one use; throws 429 once the account is over its limit.
    func spend(_ action: Action, user: String, isNewAccount: Bool) throws {
        let rule = Self.rule(action, isNewAccount: isNewAccount)
        let (count, resetIn) = store.hit(key: "\(action.rawValue):\(user)", windowSeconds: rule.window)
        guard count > rule.max else { return }
        let minutes = max(1, Int((resetIn / 60).rounded(.up)))
        throw InlineError(.tooManyRequests, "You're doing that too often. Please try again in \(minutes) minute\(minutes == 1 ? "" : "s").")
    }
}

extension Request {
    /// Refuses a restricted account, then counts one use of `action`.
    func requireNotRestricted(spending action: UserRateLimiter.Action) throws {
        try requireNotRestricted()
        try spend(action)
    }

    func spend(_ action: UserRateLimiter.Action) throws {
        try UserRateLimiter.shared.spend(action, user: userID, isNewAccount: accountIsNew)
    }

    /// Why a brand-new account can't put a link in front of strangers.
    func requireNoLinkToStrangers(in text: String?) throws {
        guard accountIsNew, let text, ModerationRules.containsLink(text) else { return }
        throw InlineError(.forbidden, "Links aren't available to new accounts yet. Try again in a couple of days.")
    }
}
