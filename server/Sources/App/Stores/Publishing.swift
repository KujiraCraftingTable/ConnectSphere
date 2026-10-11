import Vapor

/// How a new post is saved: published now, kept as a draft, or scheduled.
/// Threaded through every post creator so drafts skip the side effects of
/// going live (counters, AI tagging, embeddings) until they actually do.
struct Publishing {
    /// posts.status: posted | draft | scheduled
    var status: String
    var publishAt: Date?
    /// Dates inside the post (poll end, event start, job deadline) must fall
    /// after this. nil for a draft: those are checked when it's published.
    var datesAfter: Date?

    var isLive: Bool { status == "posted" }

    static var now: Publishing { Publishing(status: "posted", publishAt: nil, datesAfter: Date()) }
    static let draft = Publishing(status: "draft", publishAt: nil, datesAfter: nil)

    /// From a create body's `publish` field ("now" | "draft"; absent = now).
    static func from(_ publish: String?) throws -> Publishing {
        switch publish ?? "now" {
        case "now": return .now
        case "draft": return .draft
        default: throw InlineError(.badRequest, "publish must be now or draft")
        }
    }
}
