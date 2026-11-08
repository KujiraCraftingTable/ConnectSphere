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
    case datingProfile = "dating_profile"

    private static let common: [ModerationPolicy] = [
        .spam, .scam, .harassment, .hate, .nuditySexual, .childSafety,
        .violence, .selfHarm, .illegalGoods, .misinformation, .other,
    ]

    var reasons: [ModerationPolicy] {
        switch self {
        case .post: Self.common + [.offTopic]
        case .comment, .message, .story: Self.common
        case .user, .community, .company: Self.common + [.impersonation]
        case .datingProfile: Self.common + [.impersonation, .underage]
        }
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

enum Restrictions {
    /// The app shows its own wording; the date is for it to format.
    static func message(until: Date) -> String {
        "Your account can't post, comment or message new people until \(ISO8601DateFormatter().string(from: until))"
    }
}
