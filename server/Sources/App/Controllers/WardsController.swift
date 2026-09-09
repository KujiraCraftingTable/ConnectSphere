import Vapor
import SQLKit

/// Port of `backend/src/routes/wardRoutes.js` — the Vietnam ward/province
/// reference data for the location pickers. **No auth** (matches Node: mounted
/// before any auth middleware).
struct WardsController {
    static func register(routes: any RoutesBuilder) {
        let w = routes.grouped("wards")
        w.get("provinces", use: provinces)
        w.get(use: list)
    }

    struct Province: Content { var province_code: String; var province_name: String; var province_name_en: String? }
    static func provinces(_ req: Request) async throws -> DataListResponse<Province> {
        let rows = try await req.db.sql().raw("""
            SELECT DISTINCT province_code, province_name, province_name_en
            FROM vn_wards ORDER BY province_name
            """).all(decoding: Province.self)
        return DataListResponse(data: rows)
    }

    struct Ward: Content {
        var id: String; var code: String; var name: String
        @NullCoded var name_en: String?; @NullCoded var full_name: String?; @NullCoded var full_name_en: String?
        @NullCoded var unit_type: String?; @NullCoded var lat: Double?; @NullCoded var lng: Double?
    }
    static func list(_ req: Request) async throws -> DataListResponse<Ward> {
        guard let code = try? req.query.get(String.self, at: "province_code") else {
            throw StatusMessageError(.badRequest, "province_code is required")
        }
        let rows = try await req.db.sql().raw("""
            SELECT id::text AS id, code, name, name_en, full_name, full_name_en, unit_type, lat, lng
            FROM vn_wards WHERE province_code = \(bind: code) ORDER BY name
            """).all(decoding: Ward.self)
        return DataListResponse(data: rows)
    }
}
