import Foundation

extension Notification.Name {
    /// A draft was saved, published or deleted: the drafts list and the
    /// composer's "Drafts" count refresh.
    static let draftsChanged = Notification.Name("draftsChanged")
}

/// How the composer saves a post. A post opened from a draft also sends the
/// draft's id (`replaces_draft`): the server saves the new version, then
/// removes the old one, so a draft is never left behind twice.
enum PublishChoice: Equatable {
    case now
    case draft

    var isLive: Bool { self == .now }

    func apply(to body: inout [String: Any], replacing draftId: String?) {
        if self == .draft { body["publish"] = "draft" }
        if let draftId { body["replaces_draft"] = draftId }
    }
}

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
