import Foundation

// MARK: - Notifications
extension Notification.Name {
    /// The muted-word list changed (either mode): feeds refetch so posts the
    /// server now hides (or shows again) update without a manual refresh.
    static let mutedWordsChanged = Notification.Name("mutedWordsChanged")
}

// MARK: - Muted word
/// A word or phrase the user doesn't want to see, in one mode (migration 042).
/// The server does the matching: accents and capitals are ignored and only
/// whole words count.
struct MutedWord: Identifiable, Decodable, Equatable {
    let id: String
    let word: String
    let expiresAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, word
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    enum Remaining: Equatable {
        case forever, days(Int), hours(Int), underAnHour
    }

    /// How long the mute lasts from `now`, rounded up so a fresh "7 days"
    /// reads "7 days left", not "6".
    func remaining(at now: Date = Date()) -> Remaining {
        guard let expiresAt else { return .forever }
        let seconds = max(0, expiresAt.timeIntervalSince(now))
        if seconds >= 86_400 { return .days(Int((seconds / 86_400).rounded(.up))) }
        if seconds >= 3_600 { return .hours(Int((seconds / 3_600).rounded(.up))) }
        return .underAnHour
    }
}

// MARK: - Durations
/// The durations the server accepts (`MutedWordStore.durations`).
enum MuteDuration: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d", forever

    var id: String { rawValue }

    /// Localization key, callers wrap it in `bundle.loc(...)`.
    var label: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Forever"
        }
    }
}
