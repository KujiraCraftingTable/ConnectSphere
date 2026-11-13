import Vapor
import SQLKit

/// The notices that close the loop (migration 089): the reporter hears that
/// the report arrived and how it ended, the author hears what was done and
/// why, with a way to appeal. Reporters are never named to the author.
/// Fire-and-forget, like every notification: a failed notice never undoes
/// the decision.
enum ModerationNotices {
    /// `communityID`: the report went to that community's moderators, and the
    /// reporter is told so, so they know it reached someone who'll act on it.
    static func reportReceived(reporter: String, type: ReportTarget, communityID: String? = nil,
                               on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        await NotifyService.pushUserNotification(userID: reporter, type: "report_received", communityID: communityID,
                                                 payload: ["targetType": type.rawValue], on: db, hub: hub, logger: logger)
    }

    /// The author is told when the automatic check hid something for review.
    static func held(caseID: String, authorID: String, target: ReportTarget,
                     on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        await NotifyService.pushUserNotification(userID: authorID, type: "content_held", groupTargetID: caseID,
                                                 payload: ["caseId": caseID, "targetType": target.rawValue],
                                                 on: db, hub: hub, logger: logger)
    }

    static func decided(_ o: ModerationService.Outcome, on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        guard let c = try? await ModerationService.loadCase(o.caseID, on: db) else { return }
        // Every reporter hears the outcome once, whatever they each picked.
        struct R: Decodable { let reporter_id: String }
        let reporters = (try? await db.raw("""
            SELECT DISTINCT reporter_id::text AS reporter_id FROM content_reports WHERE case_id = \(uuid: o.caseID)
            """).all(decoding: R.self)) ?? []
        // Only the message written for reporters; the private note stays with staff.
        let note = await reporterMessage(o.caseID, on: db)
        var reporterPayload: [String: Any] = ["targetType": c.target_type,
                                              "outcome": ReportOutcome.of(decision: o.decision, targetType: c.target_type)]
        if let note, !note.isEmpty { reporterPayload["note"] = note }
        for r in reporters {
            await NotifyService.pushUserNotification(
                userID: r.reporter_id, type: "report_outcome",
                payload: reporterPayload, on: db, hub: hub, logger: logger)
        }
        // A kept report is nothing the author needs to hear about — unless the
        // check had already hidden it, and now it's back.
        // A kept report still reaches the author: they hear it was looked at
        // and nothing was done, never who reported it.
        if o.decision == .keep, !c.auto_hidden, let author = o.authorID {
            await NotifyService.pushUserNotification(userID: author, type: "report_reviewed", groupTargetID: o.caseID,
                                                     payload: ["caseId": o.caseID, "targetType": c.target_type],
                                                     on: db, hub: hub, logger: logger)
        }
        if o.decision == .keep, c.auto_hidden, let author = o.authorID {
            await NotifyService.pushUserNotification(userID: author, type: "appeal_outcome", groupTargetID: o.caseID,
                                                     payload: ["caseId": o.caseID, "outcome": "overturned"],
                                                     on: db, hub: hub, logger: logger)
        }
        guard o.decision != .keep, let author = o.authorID else { return }
        var payload: [String: Any] = ["caseId": o.caseID, "targetType": c.target_type, "policy": c.policy,
                                      "decision": o.decision.rawValue, "appealDays": Enforcement.appealWindowDays]
        if let hours = o.restrictedHours {
            payload["restrictedHours"] = hours
            // Older apps read only days; they get them when the length is whole days.
            if hours % 24 == 0 { payload["restrictedDays"] = hours / 24 }
        }
        await NotifyService.pushUserNotification(userID: author, type: "moderation_decision", groupTargetID: o.caseID,
                                                 payload: payload, on: db, hub: hub, logger: logger)
    }

    static func appealDecided(_ o: ModerationService.AppealOutcome, on db: any SQLDatabase, hub: SocketHub, logger: Logger) async {
        await NotifyService.pushUserNotification(userID: o.userID, type: "appeal_outcome", groupTargetID: o.caseID,
                                                 payload: ["caseId": o.caseID, "outcome": o.overturned ? "overturned" : "upheld"],
                                                 on: db, hub: hub, logger: logger)
        // Reporters were told it came down; they hear it's back, never who appealed.
        guard o.overturned, let c = try? await ModerationService.loadCase(o.caseID, on: db) else { return }
        struct R: Decodable { let reporter_id: String }
        let reporters = (try? await db.raw("""
            SELECT DISTINCT reporter_id::text AS reporter_id FROM content_reports WHERE case_id = \(uuid: o.caseID)
            """).all(decoding: R.self)) ?? []
        var payload: [String: Any] = ["targetType": c.target_type, "outcome": "restored"]
        if let note = await reporterMessage(o.caseID, on: db) { payload["note"] = note }
        for r in reporters where r.reporter_id != o.userID {
            await NotifyService.pushUserNotification(userID: r.reporter_id, type: "report_restored",
                                                     payload: payload, on: db, hub: hub, logger: logger)
        }
    }

    private static func reporterMessage(_ caseID: String, on db: any SQLDatabase) async -> String? {
        struct N: Decodable { let reporter_message: String? }
        let n = (try? await db.raw("SELECT reporter_message FROM moderation_cases WHERE id = \(uuid: caseID)")
            .first(decoding: N.self))??.reporter_message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// Emails a warning or ban to the person's verified address, if they have one.
    /// Never fails the decision: it runs detached and only logs.
    static func email(_ o: ModerationService.Outcome, app: Application, logger: Logger) {
        guard o.decision == .warn || o.decision == .ban, let author = o.authorID else { return }
        Task {
            let db = app.db.sql()
            struct U: Decodable { let email: String?; let verified: Bool }
            struct C: Decodable { let policy: String; let mode: String? }
            struct B: Decodable { let banned_until: Date? }
            guard let u = try? await db.raw("""
                    SELECT email, (email_verified_at IS NOT NULL) AS verified FROM users WHERE id = \(uuid: author)
                    """).first(decoding: U.self),
                  let email = u.email, u.verified,
                  let c = try? await db.raw("SELECT policy, mode FROM moderation_cases WHERE id = \(uuid: o.caseID)")
                    .first(decoding: C.self) else { return }
            let until = (try? await db.raw("""
                SELECT banned_until FROM account_bans WHERE case_id = \(uuid: o.caseID) ORDER BY banned_at DESC LIMIT 1
                """).first(decoding: B.self))??.banned_until
            let warnings = (try? await AccountBans.activeWarnings(author, mode: c.mode ?? "hobby", on: db)) ?? 1
            do {
                try await Mailer(app: app, logger: logger).sendModerationNotice(
                    to: email, ban: o.decision == .ban, reason: c.policy.replacingOccurrences(of: "_", with: " "),
                    mode: c.mode, until: until, warnings: warnings)
            } catch {
                logger.warning("moderation email failed for case \(o.caseID): \(error)")
            }
        }
    }
}
