import Vapor
import SQLKit

/// Per-mode bans (migration 106). Banned in a mode, that persona is gone for
/// everyone else there and its owner only sees the ban notice in that mode.
/// Banned in both modes is the whole account; permanent in both also blocks
/// the email and Google account from signing up again.
enum AccountBans {
    static let modes = ["hobby", "work"]
    /// Ban lengths the admin can pick; nil is permanent.
    static let allowedDays: Set<Int> = [7, 30, 90, 365]
    /// Active warnings in one mode that turn into a ban.
    static let warningsForBan = 3

    /// SQL: is `userRef` banned in `modeRef` right now? Both refs are column
    /// names or quoted literals chosen by the code, never request input.
    static func bannedInSQL(_ userRef: String, _ modeRef: String) -> String {
        """
        EXISTS (SELECT 1 FROM account_bans ab WHERE ab.user_id = \(userRef) AND ab.mode = \(modeRef)
          AND ab.lifted_at IS NULL AND (ab.banned_until IS NULL OR ab.banned_until > NOW()))
        """
    }

    /// The pure rule behind `bannedInSQL`, for tests and in-memory checks.
    static func isActive(liftedAt: Date?, bannedUntil: Date?, now: Date = Date()) -> Bool {
        liftedAt == nil && (bannedUntil.map { $0 > now } ?? true)
    }

    /// A requested length: one of `allowedDays`, or nil for permanent.
    static func validDays(_ days: Int?) -> Bool { days.map(allowedDays.contains) ?? true }

    /// The modes `userID` is banned in right now.
    static func activeModes(_ userID: String, on db: any SQLDatabase) async throws -> Set<String> {
        struct R: Decodable { let mode: String }
        let rows = try await db.raw("""
            SELECT DISTINCT mode FROM account_bans
            WHERE user_id = \(uuid: userID) AND lifted_at IS NULL AND (banned_until IS NULL OR banned_until > NOW())
            """).all(decoding: R.self)
        return Set(rows.map(\.mode))
    }

    /// Bans `userID` in `modes` (replacing an active ban there) for `days`,
    /// or permanently when nil.
    static func ban(_ userID: String, modes: [String], caseID: String?, days: Int?, on t: any SQLDatabase) async throws {
        for mode in modes where Self.modes.contains(mode) {
            try await t.raw("""
                UPDATE account_bans SET lifted_at = NOW()
                WHERE user_id = \(uuid: userID) AND mode = \(bind: mode) AND lifted_at IS NULL
                """).run()
            try await t.raw("""
                INSERT INTO account_bans (user_id, mode, case_id, banned_until)
                VALUES (\(uuid: userID), \(bind: mode), \(uuid: caseID),
                        CASE WHEN \(bind: days)::int IS NULL THEN NULL ELSE NOW() + make_interval(days => \(bind: days)::int) END)
                """).run()
        }
        try await rememberIdentityIfPermanentEverywhere(userID, on: t)
    }

    /// Overturned on appeal: lifts the bans that case made.
    static func lift(caseID: String, on t: any SQLDatabase) async throws {
        struct R: Decodable { let user_id: String }
        let users = try await t.raw("""
            UPDATE account_bans SET lifted_at = NOW() WHERE case_id = \(uuid: caseID) AND lifted_at IS NULL
            RETURNING user_id::text AS user_id
            """).all(decoding: R.self)
        for u in Set(users.map(\.user_id)) {
            try await t.raw("DELETE FROM banned_identities WHERE user_id = \(uuid: u)").run()
        }
    }

    /// Permanently banned in both modes: keep the email and Google id so the
    /// person can't sign up again with them.
    private static func rememberIdentityIfPermanentEverywhere(_ userID: String, on t: any SQLDatabase) async throws {
        struct N: Decodable { let n: Int }
        let permanent = try await t.raw("""
            SELECT COUNT(DISTINCT mode)::int AS n FROM account_bans
            WHERE user_id = \(uuid: userID) AND lifted_at IS NULL AND banned_until IS NULL
            """).first(decoding: N.self)?.n ?? 0
        guard permanent == modes.count else { return }
        try await t.raw("""
            INSERT INTO banned_identities (user_id, email, google_id)
            SELECT id, lower(email), google_id FROM users
            WHERE id = \(uuid: userID) AND (email IS NOT NULL OR google_id IS NOT NULL)
              AND NOT EXISTS (SELECT 1 FROM banned_identities b WHERE b.user_id = users.id)
            """).run()
    }

    /// Refuses an email or Google account that belonged to a permanently
    /// banned account.
    static func refuseBannedIdentity(email: String?, googleID: String?, on db: any SQLDatabase) async throws {
        let email = email?.trimmingCharacters(in: .whitespaces).lowercased()
        guard email?.isEmpty == false || googleID?.isEmpty == false else { return }
        struct R: Decodable { let one: Int }
        if try await db.raw("""
            SELECT 1 AS one FROM banned_identities
            WHERE (\(bind: email)::text IS NOT NULL AND lower(email) = \(bind: email)::text)
               OR (\(bind: googleID)::text IS NOT NULL AND google_id = \(bind: googleID)::text)
            LIMIT 1
            """).first(decoding: R.self) != nil {
            throw InlineError(.forbidden, "This email can't be used to create an account")
        }
    }

    /// Active warnings (strikes) in `mode`; a strike from before modes counts in both.
    static func activeWarnings(_ userID: String, mode: String, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await db.raw("""
            SELECT COUNT(*)::int AS n FROM moderation_strikes
            WHERE user_id = \(uuid: userID) AND revoked_at IS NULL AND expires_at > NOW()
              AND (mode = \(bind: mode) OR mode IS NULL)
            """).first(decoding: N.self)?.n ?? 0
    }

    // MARK: hiding a banned persona from everyone else

    /// SQL: `userRef`'s persona in the mode held by `modeColumn` is visible to
    /// `viewer`: not banned there, or the viewer is the official account.
    static func visible(userRef: String, modeColumn: String, viewer: String) -> SQLQueryString {
        "(NOT \(unsafeRaw: bannedInSQL(userRef, modeColumn)) OR \(adminViewer(viewer)))"
    }

    /// The same, with the mode as a value (bound, not inlined).
    static func visible(userRef: String, mode: String, viewer: String) -> SQLQueryString {
        """
        (NOT EXISTS (SELECT 1 FROM account_bans ab WHERE ab.user_id = \(unsafeRaw: userRef) AND ab.mode = \(bind: mode)
          AND ab.lifted_at IS NULL AND (ab.banned_until IS NULL OR ab.banned_until > NOW()))
         OR \(adminViewer(viewer)))
        """
    }

    /// SQL: `viewer` is the official account, which sees past every lock and filter.
    static func adminViewer(_ viewer: String) -> SQLQueryString {
        "EXISTS (SELECT 1 FROM users av WHERE av.id = \(uuid: viewer) AND av.app_role = 'admin' AND av.deleted_at IS NULL)"
    }

    /// Refuses reaching `userID` in `mode` (message, follow, connect) while banned there.
    static func refuseIfBanned(_ userID: String, mode: String, on db: any SQLDatabase) async throws {
        if try await activeModes(userID, on: db).contains(mode) {
            throw InlineError(.notFound, "User not found")
        }
    }

    /// Refuses writing in a 1-on-1 chat whose other person is banned in the
    /// chat's mode: old messages stay, nobody can write to them.
    static func refuseIfPeerBanned(conversationID: String, sender: String, on db: any SQLDatabase) async throws {
        struct R: Decodable { let one: Int }
        if try await db.raw("""
            SELECT 1 AS one FROM conversations c
            JOIN conversation_participants o ON o.conversation_id = c.id AND o.user_id <> \(uuid: sender)
            WHERE c.id = \(uuid: conversationID) AND NOT c.is_group
              AND \(unsafeRaw: bannedInSQL("o.user_id", "c.mode"))
            LIMIT 1
            """).first(decoding: R.self) != nil {
            throw InlineError(.forbidden, "This person can't receive messages right now")
        }
    }
}
