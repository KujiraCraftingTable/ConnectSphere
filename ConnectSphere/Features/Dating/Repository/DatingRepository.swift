import Foundation

/// `/api/dating` — HTTP + decoding only.
struct DatingRepository {
    private let client = NetworkClient.shared

    private struct ListResponse<T: Decodable>: Decodable { let data: [T] }
    private struct OK: Decodable { let ok: Bool }

    func status(token: String) async throws -> DatingStatus {
        try await client.fetch(DatingStatus.self, path: "/dating/me", token: token)
    }

    /// Saves the whole profile (photos already uploaded) and turns it on.
    func save(_ profile: DatingProfile, token: String) async throws -> DatingProfile {
        struct Body: Encodable {
            let bio: String; let interested_in: String; let min_age: Int; let max_age: Int
            let max_distance_km: Int?; let height_cm: Int?; let has_kids: String?; let city: String
            let latitude: Double; let longitude: Double; let photos: [String]
        }
        let body = Body(bio: profile.bio, interested_in: profile.interestedIn.rawValue,
                        min_age: profile.minAge, max_age: profile.maxAge,
                        max_distance_km: profile.maxDistanceKm, height_cm: profile.heightCm,
                        has_kids: profile.hasKids?.rawValue, city: profile.city,
                        latitude: profile.latitude, longitude: profile.longitude, photos: profile.photos)
        return try await client.fetch(DatingProfile.self, path: "/dating/me", method: "PUT", token: token,
                                      bodyData: try JSONEncoder().encode(body))
    }

    func setActive(_ active: Bool, token: String) async throws {
        struct Body: Encodable { let is_active: Bool }
        _ = try await client.fetch(OK.self, path: "/dating/me", method: "PATCH", token: token,
                                   bodyData: try JSONEncoder().encode(Body(is_active: active)))
    }

    /// The phone's latest position, named by its district and city.
    func updateLocation(city: String, latitude: Double, longitude: Double, token: String) async throws {
        struct Body: Encodable { let city: String; let latitude: Double; let longitude: Double }
        _ = try await client.fetch(OK.self, path: "/dating/me", method: "PATCH", token: token,
                                   bodyData: try JSONEncoder().encode(Body(city: city, latitude: latitude, longitude: longitude)))
    }

    func deleteProfile(token: String) async throws {
        _ = try await client.fetch(OK.self, path: "/dating/me", method: "DELETE", token: token)
    }

    func browse(token: String) async throws -> [DatingCard] {
        try await client.fetch(ListResponse<DatingCard>.self, path: "/dating/browse", token: token).data
    }

    func respond(to userId: String, liked: Bool, token: String) async throws -> DatingLikeResult {
        struct Body: Encodable { let user_id: String; let liked: Bool }
        return try await client.fetch(DatingLikeResult.self, path: "/dating/likes", method: "POST", token: token,
                                      bodyData: try JSONEncoder().encode(Body(user_id: userId, liked: liked)))
    }

    func likesYou(token: String) async throws -> [DatingLiker] {
        try await client.fetch(ListResponse<DatingLiker>.self, path: "/dating/likes", token: token).data
    }

    func matches(token: String) async throws -> [DatingMatch] {
        try await client.fetch(ListResponse<DatingMatch>.self, path: "/dating/matches", token: token).data
    }

    func unmatch(_ matchId: String, token: String) async throws {
        _ = try await client.fetch(OK.self, path: "/dating/matches/\(matchId)", method: "DELETE", token: token)
    }
}
