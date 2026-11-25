import Foundation

// MARK: - Notifications
extension Notification.Name {
    /// A draft was saved, published or deleted: the drafts list and the
    /// composer's "Drafts" count refresh.
    static let draftsChanged = Notification.Name("draftsChanged")
}

// MARK: - Publish choice
/// How the composer saves a post. A post opened from a draft also sends the
/// draft's id (`replaces_draft`): the server saves the new version, then
/// removes the old one, so a draft is never left behind twice.
enum PublishChoice: Equatable {
    case now
    case draft
    /// Goes out at this time (5 minutes to 6 months ahead).
    case schedule(Date)

    var isLive: Bool { self == .now }

    func apply(to body: inout [String: Any], replacing draftId: String?) {
        switch self {
        case .now: break
        case .draft: body["publish"] = "draft"
        case .schedule(let date):
            body["publish"] = "schedule"
            body["publish_at"] = ISO8601DateFormatter().string(from: date)
        }
        if let draftId { body["replaces_draft"] = draftId }
    }
}

// MARK: - Schedule window
/// The times a post can be scheduled for. The server's window, with a
/// minute's slack so a time picked right at the edge isn't refused.
enum ScheduleWindow {
    static func range(from now: Date = Date()) -> ClosedRange<Date> {
        now.addingTimeInterval(6 * 60)...now.addingTimeInterval(180 * 86_400 - 60)
    }

    /// What the picker starts on: the next whole hour at least an hour away.
    static func suggested(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let inAnHour = now.addingTimeInterval(3600)
        let hour = cal.dateInterval(of: .hour, for: inAnHour)?.start ?? inAnHour
        return hour < inAnHour ? hour.addingTimeInterval(3600) : hour
    }
}

// MARK: - Draft snippet
extension Post {
    /// The one line a drafts list shows: the text, or what the post holds.
    var draftSnippet: String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if let title = eventData?.title ?? jobData?.title { return title }
        if !imageUrls.isEmpty { return Bundle.app.loc(imageUrls.count == 1 ? "Photo" : "Photos") }
        if let link = linkUrl { return articleTitle ?? link }
        return Bundle.app.loc("Empty draft")
    }
}
