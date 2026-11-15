import Vapor
import SQLKit

/// A user's ward: their private home point for distance search. Only its
/// province is ever shown, as `users.location`.
enum WardStore {
    struct Ward: Decodable {
        let id: String
        /// In the spelling sign-up used before wards ("Ho Chi Minh", "Hanoi"),
        /// so existing locations and the AI's place names still match it.
        let province: String
        let lat: Double
        let lng: Double
    }

    /// "Ho Chi Minh City" → "Ho Chi Minh". Ha Noi is the one province whose app
    /// id is spelled differently ("Hanoi").
    private static let provinceSQL: SQLQueryString =
        "REPLACE(REGEXP_REPLACE(w.province_name_en, ' (City|Province)$', ''), 'Ha Noi', 'Hanoi')"

    static func find(_ id: String, on db: any SQLDatabase) async throws -> Ward? {
        guard UUID(uuidString: id) != nil else { return nil }
        return try await db.raw("""
            SELECT w.id::text AS id, \(provinceSQL) AS province, w.lat, w.lng
            FROM vn_wards w WHERE w.id = \(uuid: id)
            """).first(decoding: Ward.self)
    }

    /// The ward a request names, or a 400. Sign-up and profile edits both need one.
    static func require(_ id: String?, on db: any SQLDatabase) async throws -> Ward {
        let raw = (id ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw InlineError(.badRequest, "ward_id is required") }
        guard let ward = try await find(raw, on: db) else { throw InlineError(.badRequest, "Unknown ward") }
        return ward
    }

    /// `vn_wards.province_code` of the province with this app name ("Ho Chi
    /// Minh"), or else of the user's own ward: the province an ambiguous place
    /// name is read in (`PlaceReader`).
    static func provinceCode(named province: String?, orOfUser userID: String, on db: any SQLDatabase) async throws -> String? {
        struct Row: Decodable { let province_code: String }
        if let province {
            let named = try await db.raw("""
                SELECT w.province_code FROM vn_wards w WHERE \(provinceSQL) = \(bind: province) LIMIT 1
                """).first(decoding: Row.self)
            if let named { return named.province_code }
        }
        return try await db.raw("""
            SELECT w.province_code FROM users u JOIN vn_wards w ON w.id = u.ward_id WHERE u.id = \(uuid: userID)
            """).first(decoding: Row.self)?.province_code
    }

    /// The app name of a province ("Ho Chi Minh") from its code.
    static func provinceName(code: String, on db: any SQLDatabase) async throws -> String? {
        struct Row: Decodable { let province: String }
        return try await db.raw("""
            SELECT \(provinceSQL) AS province FROM vn_wards w WHERE w.province_code = \(bind: code) LIMIT 1
            """).first(decoding: Row.self)?.province
    }

    /// The centre of a user's ward, the default point a search radius is measured from.
    static func centre(ofUser userID: String, on db: any SQLDatabase) async throws -> (lat: Double, lng: Double)? {
        struct Row: Decodable { let lat: Double; let lng: Double }
        guard let r = try await db.raw("""
            SELECT w.lat, w.lng FROM users u JOIN vn_wards w ON w.id = u.ward_id
            WHERE u.id = \(uuid: userID)
            """).first(decoding: Row.self) else { return nil }
        return (r.lat, r.lng)
    }
}
