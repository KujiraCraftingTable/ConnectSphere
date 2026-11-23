import Foundation

/// The one list of rules that report reasons, AI verdicts, notices and
/// strikes all speak. Severity follows the big platforms' split (Meta since
/// January 2025): automation acts alone only on the severe end; the rest waits
/// for a person.
enum ModerationPolicy: String, CaseIterable, Codable, Sendable {
    case childSafety = "child_safety"
    case nuditySexual = "nudity_sexual"
    case violence
    case selfHarm = "self_harm"
    case scam
    case hate
    case harassment
    case spam
    case illegalGoods = "illegal_goods"
    case impersonation
    case underage
    case misinformation
    case offTopic = "off_topic"
    case other

    /// 0 = zero tolerance … 3 = acted on only after a user report and a person.
    var severity: Int {
        switch self {
        case .childSafety: 0
        case .nuditySexual, .violence, .selfHarm, .scam: 1
        case .hate, .harassment, .spam, .illegalGoods: 2
        case .impersonation, .underage, .misinformation, .offTopic, .other: 3
        }
    }
}

/// What can be reported, and with which reasons.
enum ReportTarget: String, CaseIterable, Sendable {
    case post, comment, message, user, community, story, company

    private static let common: [ModerationPolicy] = [
        .spam, .scam, .harassment, .hate, .nuditySexual, .childSafety,
        .violence, .selfHarm, .illegalGoods, .misinformation, .other,
    ]

    var reasons: [ModerationPolicy] {
        switch self {
        case .post: Self.common + [.offTopic]
        case .comment, .message, .story: Self.common
        case .user, .community, .company: Self.common + [.impersonation]        }
    }
}

enum ReportRules {
    enum Problem: Error, Equatable { case badTarget, badReason, detailTooLong }

    static let maxDetail = 500

    /// Validates a report body; returns the trimmed detail (nil when blank).
    static func validate(target: String?, reason: String?, detail: String?) throws -> (ReportTarget, ModerationPolicy, String?) {
        guard let t = target.flatMap(ReportTarget.init(rawValue:)) else { throw Problem.badTarget }
        guard let r = reason.flatMap(ModerationPolicy.init(rawValue:)), t.reasons.contains(r) else { throw Problem.badReason }
        let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (d?.count ?? 0) <= maxDetail else { throw Problem.detailTooLong }
        return (t, r, (d?.isEmpty ?? true) ? nil : d)
    }

    /// Community content is the community staff's to judge for these; anything
    /// else (harm, not house rules) also needs the app's moderators.
    static let communityOnly: Set<ModerationPolicy> = [.offTopic, .spam, .misinformation, .other]

    /// `community_reports.reason` predates the shared policy list.
    static func communityReason(_ p: ModerationPolicy) -> String {
        switch p {
        case .spam, .harassment, .misinformation: p.rawValue
        case .hate: "hate_speech"
        case .offTopic: "off_topic"
        default: "other"
        }
    }
}

/// What an admin can decide on a case. Every outcome except `keep` takes the
/// content down; `restrict` and `ban` also act on the account.
enum ModerationDecision: String, CaseIterable, Sendable {
    case keep, remove
    case removeStrike = "remove_strike"
    case restrict, ban
    /// The official account's warning (migration 106): a strike in the item's
    /// mode; three active in one mode turn into a ban.
    case warn

    var removesContent: Bool { self != .keep }
}

enum Enforcement {
    static let maxRestrictDays = 30
    /// Restrictions shorter than a day a moderator can pick; anything longer is
    /// whole days, up to `maxRestrictDays`.
    static let shortRestrictHours: Set<Int> = [6, 12]

    static func isValidRestriction(hours: Int) -> Bool {
        shortRestrictHours.contains(hours)
            || (hours % 24 == 0 && (1...maxRestrictDays).contains(hours / 24))
    }
    static let appealWindowDays = 30

    /// Meta-style ladder over the strikes active in the last 90 days: the
    /// first is a warning, then the account can't post, comment or message
    /// strangers for 1, 3, 7, then 30 days (where an admin looks at a ban).
    static func restrictionDays(activeStrikes: Int) -> Int? {
        switch activeStrikes {
        case ...1: nil
        case 2: 1
        case 3: 3
        case 4: 7
        default: 30
        }
    }

    /// A strike for zero-tolerance harm is a ban, whatever the count.
    static func escalate(_ decision: ModerationDecision, policy: ModerationPolicy) -> ModerationDecision {
        decision == .removeStrike && policy == .childSafety ? .ban : decision
    }

    static func canAppeal(decidedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(decidedAt) <= Double(appealWindowDays) * 86_400
    }
}

/// A restricted account is read-only in that mode: it can look at everything
/// but change or interact with nothing, apart from its settings, safety tools
/// (block, mute, report, appeal) and the passive calls reading makes.
enum Restrictions {
    /// The app shows the end date itself (Account Status), in the reader's format.
    static let message = "Your account is read-only for now. See Account Status for details."

    /// `PATCH /users/me` keys that are settings, not profile content.
    static let settingsKeys: Set<String> = [
        "allow_friend_requests", "show_in_suggestions", "track_activity", "links_other_mode", "locked",
        "dob_visibility", "hobby_theme", "work_theme", "mode",
    ]

    /// Writes a restricted account may still make, as (methods, path after
    /// `/api/`). `*` is one segment, a trailing `**` any rest.
    private static let open: [(Set<String>, String)] = [
        // What reading does on its own.
        (["POST"], "feed/impressions"), (["POST"], "stories/*/view"), (["POST"], "communities/*/opened"),
        (["POST"], "search/**"), (["POST"], "entities/alias"), (["POST"], "link-preview"),
        (["PUT"], "messages/conversations/*/read"), (["PUT"], "messages/conversations/*/delivered"),
        (["POST"], "messages/conversations/*/block-alert-ack"),
        (["POST", "PATCH", "DELETE"], "notifications/**"), (["POST", "PATCH", "DELETE"], "user-notifications/**"),
        // Settings and personal organisation.
        (["PATCH"], "users/me"), (["PATCH"], "users/me/default-mode"), (["DELETE"], "users/me"),
        (["POST", "PATCH", "DELETE"], "users/me/email/**"), (["POST"], "users/me/export"), (["POST"], "users/me/export/**"),
        (["POST"], "users/me/deletion/code"), (["DELETE"], "users/me/personas/*"),
        (["POST", "PATCH"], "users/me/two-factor"), (["POST"], "users/me/two-factor/**"),
        (["POST"], "auth/change-password"),
        (["PUT"], "messages/conversations/*/pin"), (["PUT"], "messages/conversations/*/archive"), (["PUT"], "messages/conversations/*/mute"),
        (["PUT", "DELETE"], "communities/*/mute"), (["PUT", "DELETE"], "communities/*/pin"),
        (["PUT"], "communities/*/notifications"),
        (["POST", "PUT", "PATCH", "DELETE"], "spaces/**"), (["POST", "PUT", "PATCH", "DELETE"], "spaces"),
        (["POST", "DELETE"], "posts/*/hide"), (["POST", "DELETE"], "posts/*/feedback"), (["POST"], "people/suggestions/*/dismiss"),
        // Safety tools.
        (["POST", "DELETE"], "users/*/block"), (["PUT", "DELETE"], "users/*/hide-posts"),
        (["POST", "DELETE"], "muted-words/**"), (["POST"], "muted-words"),
        (["POST"], "reports"), (["POST"], "appeals"), (["POST"], "posts/*/report"),
        (["POST"], "communities/*/report"), (["POST"], "communities/*/members/*/report"),
    ]

    /// Whether a restricted account may make this request.
    static func allows(method: String, path: String) -> Bool {
        let method = method.uppercased()
        if ["GET", "HEAD", "OPTIONS"].contains(method) { return true }
        guard path.hasPrefix("/api/") else { return false }
        let parts = path.dropFirst(5).split(separator: "/").map(String.init)
        return open.contains { methods, pattern in
            methods.contains(method) && matches(parts, pattern.split(separator: "/").map(String.init))
        }
    }

    private static func matches(_ parts: [String], _ pattern: [String]) -> Bool {
        if pattern.last == "**" {
            let head = Array(pattern.dropLast())
            return parts.count > head.count && matches(Array(parts.prefix(head.count)), head)
        }
        guard parts.count == pattern.count else { return false }
        return zip(parts, pattern).allSatisfy { $1 == "*" || $0 == $1 }
    }
}

/// How a report ended, as its reporter sees it. Shared by account-status and
/// the report_outcome notification so both say the same thing.
enum ReportOutcome {
    /// A profile banned or warned stays up, so "removed" would be wrong.
    static func of(decision: ModerationDecision, targetType: String) -> String {
        if decision == .keep { return "kept" }
        if targetType == ReportTarget.user.rawValue && (decision == .ban || decision == .warn) { return "action_taken" }
        return "removed"
    }

    /// The same rule in SQL over `mc` (moderation_cases), plus "restored"
    /// once an appeal put the item back.
    static let sql = """
        CASE
          WHEN EXISTS (SELECT 1 FROM moderation_appeals ma WHERE ma.case_id = mc.id AND ma.status = 'overturned') THEN 'restored'
          WHEN mc.status = 'dismissed' THEN 'kept'
          WHEN mc.status = 'actioned' AND mc.target_type = 'user' AND mc.decision IN ('ban', 'warn') THEN 'action_taken'
          WHEN mc.status = 'actioned' THEN 'removed'
          ELSE 'pending' END
        """
}
