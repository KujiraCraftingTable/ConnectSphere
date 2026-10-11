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
    static func scheduled(at date: Date) -> Publishing {
        Publishing(status: "scheduled", publishAt: date, datesAfter: date)
    }

    /// From a create body's `publish` ("now" | "draft" | "schedule"; absent =
    /// now) and, for a schedule, `publish_at` (ISO 8601).
    static func from(_ publish: String?, at publishAt: String? = nil, now: Date = Date()) throws -> Publishing {
        switch publish ?? "now" {
        case "now": return .now
        case "draft": return .draft
        case "schedule":
            guard let raw = publishAt,
                  let date = JSONCoding.isoFractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw InlineError(.badRequest, "publish_at is required to schedule a post")
            }
            guard PostPublisher.validScheduleTime(date, now: now) else {
                throw InlineError(.badRequest, "A post can be scheduled from 5 minutes to 6 months ahead")
            }
            return .scheduled(at: date)
        default: throw InlineError(.badRequest, "publish must be now, draft or schedule")
        }
    }
}
