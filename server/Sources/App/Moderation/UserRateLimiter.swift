import Vapor

/// Per-account limits on what spammers do in bulk (migration 089's companion):
/// commenting, starting chats with strangers, sending friend requests. Posting
/// has no per-account cap (a product decision); spam posts are caught by the
/// content checks and reports instead.
/// The per-IP limiter can't see these — one person has many requests, one
/// network has many people — and WhatsApp's biggest spam signal is exactly
/// this: new accounts sending at high speed. Accounts younger than 48 hours get
/// a quarter of the room.
///
/// Counters live in this server process (like `RateLimitMiddleware`), so a
/// restart resets them and a second server would count separately.
struct UserRateLimiter: Sendable {
    enum Action: String, Sendable {
        case comment, newChat, friendRequest
    }

    struct Rule: Equatable, Sendable {
        let max: Int
        let window: TimeInterval
    }

    static let newAccountAge: TimeInterval = 48 * 3600

    static func rule(_ action: Action, isNewAccount: Bool) -> Rule {
        let base: Rule
        switch action {
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

    /// Throws 429 when the account has used up `action`; counts nothing.
    /// Only `record` counts, after the action went through, so a rejected
    /// attempt (a typo'd request, a 400) never eats into the allowance.
    func check(_ action: Action, user: String, isNewAccount: Bool) throws {
        let rule = Self.rule(action, isNewAccount: isNewAccount)
        let (count, resetIn) = store.peek(key: "\(action.rawValue):\(user)")
        guard count >= rule.max else { return }
        let minutes = max(1, Int((resetIn / 60).rounded(.up)))
        throw InlineError(.tooManyRequests, "You're doing that too often. Please try again in \(minutes) minute\(minutes == 1 ? "" : "s").")
    }

    /// Counts one successful use of `action`.
    func record(_ action: Action, user: String, isNewAccount: Bool) {
        let rule = Self.rule(action, isNewAccount: isNewAccount)
        _ = store.hit(key: "\(action.rawValue):\(user)", windowSeconds: rule.window)
    }
}

extension Request {
    private struct CountedActionKey: StorageKey { typealias Value = UserRateLimiter.Action }

    /// Refuses the request when the account has no room left for `action`,
    /// and marks it to be counted if it succeeds (see `countIfSucceeded`).
    func requireRoom(for action: UserRateLimiter.Action) throws {
        try UserRateLimiter.shared.check(action, user: userID, isNewAccount: accountIsNew)
        storage[CountedActionKey.self] = action
    }

    /// Called by `AuthMiddleware` with the response: only a 2xx counts.
    func countIfSucceeded(_ status: HTTPResponseStatus) {
        guard let action = storage[CountedActionKey.self], (200..<300).contains(status.code) else { return }
        UserRateLimiter.shared.record(action, user: userID, isNewAccount: accountIsNew)
    }

    /// Why a brand-new account can't put a link in front of strangers.
    func requireNoLinkToStrangers(in text: String?) throws {
        guard accountIsNew, let text, ModerationRules.containsLink(text) else { return }
        throw InlineError(.forbidden, "Links aren't available to new accounts yet. Try again in a couple of days.")
    }
}
