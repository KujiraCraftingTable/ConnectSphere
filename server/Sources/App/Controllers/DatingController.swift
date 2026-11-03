import Vapor
import SQLKit

/// `/api/dating` — the Dating space (migration 081, `DatingStore`). Every
/// route checks the account's age first: under 16 or no age gets 403, except
/// `GET /dating/me`, which answers `access: "locked"` so the app can explain.
struct DatingController {
    static func register(routes: any RoutesBuilder) {
        let d = routes.grouped("dating").grouped(AuthMiddleware())
        d.get("me", use: status)
        d.put("me", use: save)
        d.patch("me", use: patch)
        d.delete("me", use: deleteProfile)
        d.get("browse", use: browse)
        d.post("likes", use: respond)
        d.get("likes", use: likesYou)
        d.get("matches", use: matches)
        d.delete("matches", ":id", use: unmatch)
    }

    struct OK: Content { var ok: Bool }

    struct Status: Content {
        /// "open" or "locked".
        var access: String
        var min_age: Int
        /// "teen" (16–17) or "adult" (18+); null while locked.
        @NullCoded var band: String?
        @NullCoded var profile: DatingStore.Profile?
        /// Name, age and gender from the account, for the setup; null while locked.
        @NullCoded var me: DatingStore.Basics?
    }

    static let lockedReason = "Dating is only for people \(DatingRules.minAge) and older"

    /// The caller's band, or 403 when Dating is locked for them.
    @discardableResult
    static func requireAccess(_ req: Request) async throws -> DatingRules.Band {
        let account = try await DatingStore.account(req.userID, on: req.db.sql())
        guard let band = DatingRules.band(age: account?.age) else { throw InlineError(.forbidden, lockedReason) }
        return band
    }

    /// Access plus a dating profile — browsing and liking need one.
    static func requireProfile(_ req: Request) async throws {
        try await requireAccess(req)
        guard try await DatingStore.profile(req.userID, on: req.db.sql()) != nil else {
            throw InlineError(.conflict, "Set up your dating profile first")
        }
    }

    static func status(_ req: Request) async throws -> Status {
        let db = req.db.sql()
        let account = try await DatingStore.account(req.userID, on: db)
        guard let band = DatingRules.band(age: account?.age) else {
            return Status(access: "locked", min_age: DatingRules.minAge, band: nil, profile: nil, me: nil)
        }
        return Status(access: "open", min_age: DatingRules.minAge, band: band.rawValue,
                      profile: try await DatingStore.profile(req.userID, on: db),
                      me: try await DatingStore.basics(req.userID, on: db))
    }

    struct SaveBody: Content {
        var bio: String?
        var interested_in: String?
        var min_age: Int?
        var max_age: Int?
        var max_distance_km: Int?
        var height_cm: Int?
        var has_kids: String?
        var city: String?
        var latitude: Double?
        var longitude: Double?
        var photos: [String]?
    }

    static func save(_ req: Request) async throws -> DatingStore.Profile {
        try await requireAccess(req)
        let b = try req.content.decode(SaveBody.self)
        guard let interestedIn = b.interested_in, let minAge = b.min_age, let maxAge = b.max_age,
              let lat = b.latitude, let lng = b.longitude else {
            throw InlineError(.badRequest, "interested_in, min_age, max_age and a place are required")
        }
        let input = DatingRules.ProfileInput(
            bio: (b.bio ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            interestedIn: interestedIn, minAge: minAge, maxAge: maxAge,
            maxDistanceKm: b.max_distance_km, heightCm: b.height_cm, hasKids: b.has_kids,
            city: (b.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: lat, longitude: lng,
            photos: MediaPath.storable(b.photos) ?? [])
        if let problem = DatingRules.problem(with: input) { throw InlineError(.badRequest, problem) }
        guard input.photos.allSatisfy(MediaPath.ownFileExists) else {
            throw InlineError(.badRequest, "Photos must be uploaded first")
        }
        try await DatingStore.save(req.userID, input, on: req.db)
        return try await DatingStore.profile(req.userID, on: req.db.sql())!
    }

    struct PatchBody: Content {
        var is_active: Bool?
        var city: String?
        var latitude: Double?
        var longitude: Double?
    }

    /// "Take a break" (`is_active`: hidden from browse and Likes you, matches
    /// kept) and/or the phone's latest location, sent each time Dating opens.
    static func patch(_ req: Request) async throws -> OK {
        try await requireAccess(req)
        let b = try req.content.decode(PatchBody.self)
        let db = req.db.sql()
        guard try await DatingStore.profile(req.userID, on: db) != nil else {
            throw InlineError(.notFound, "You don't have a dating profile")
        }
        if let lat = b.latitude, let lng = b.longitude {
            let city = (b.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = DatingRules.locationProblem(city: city, latitude: lat, longitude: lng) {
                throw InlineError(.badRequest, problem)
            }
            try await DatingStore.updateLocation(req.userID, city: city, latitude: lat, longitude: lng, on: db)
        } else if b.is_active == nil {
            throw InlineError(.badRequest, "is_active or a location is required")
        }
        if let active = b.is_active { try await DatingStore.setActive(req.userID, active, on: db) }
        return OK(ok: true)
    }

    /// Allowed even while locked, so leaving Dating is always possible.
    static func deleteProfile(_ req: Request) async throws -> OK {
        try await DatingStore.deleteProfile(req.userID, on: req.db)
        return OK(ok: true)
    }

    static func browse(_ req: Request) async throws -> DataListResponse<DatingStore.Card> {
        try await requireProfile(req)
        return DataListResponse(data: try await DatingStore.browse(req.userID, on: req.db.sql()))
    }

    struct RespondBody: Content { var user_id: String?; var liked: Bool? }

    static func respond(_ req: Request) async throws -> DatingStore.LikeResult {
        try await requireProfile(req)
        let b = try req.content.decode(RespondBody.self)
        guard let target = b.user_id.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(), let liked = b.liked else {
            throw InlineError(.badRequest, "user_id and liked are required")
        }
        let me = req.userID
        guard try await DatingStore.canReach(me, target, on: req.db.sql()) else {
            throw InlineError(.notFound, "This person isn't in Dating")
        }
        let result = try await DatingStore.respond(me, to: target, liked: liked, on: req.db)
        if result.is_new, let conversationID = result.conversation_id {
            NotifyService.fireAndForget(req) { db, hub, log in
                for (user, other) in [(me, target), (target, me)] {
                    await NotifyService.pushUserNotification(userID: user, type: "dating_match", actorID: other,
                                                             conversationID: conversationID, on: db, hub: hub, logger: log)
                }
            }
        }
        return result
    }

    static func likesYou(_ req: Request) async throws -> DataListResponse<DatingStore.Liker> {
        try await requireProfile(req)
        return DataListResponse(data: try await DatingStore.likesYou(req.userID, on: req.db.sql()))
    }

    static func matches(_ req: Request) async throws -> DataListResponse<DatingStore.Match> {
        try await requireProfile(req)
        return DataListResponse(data: try await DatingStore.matches(req.userID, on: req.db.sql()))
    }

    /// Allowed even while locked, so a match can always be ended.
    static func unmatch(_ req: Request) async throws -> OK {
        guard let id = UUID(uuidString: req.parameters.get("id") ?? ""),
              try await DatingStore.unmatch(req.userID, matchID: id.uuidString.lowercased(), on: req.db) else {
            throw InlineError(.notFound, "Match not found")
        }
        return OK(ok: true)
    }
}
