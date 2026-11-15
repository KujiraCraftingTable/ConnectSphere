import Vapor
import SQLKit

/// The Vietnam ward/province reference data for the location pickers.
/// **No auth**: mounted before any auth middleware.
struct WardsController {
    static func register(routes: any RoutesBuilder) {
        let w = routes.grouped("wards")
        w.get("provinces", use: provinces)
        w.get(use: list)
    }

    /// `former_names`: what the units were called before the 1 July 2025
    /// merger (migration 146), so the pickers find "Bình Dương" or "Bến Nghé,
    /// Quận 1" and show which of today's units that is.
    struct Province: Content {
        var province_code: String; var province_name: String; var province_name_en: String?
        var former_names: [String]
        /// The same names in English, in the same order ("Binh Duong Province").
        var former_names_en: [String] = []
    }
    private struct ProvinceRow: Decodable {
        let province_code: String; let province_name: String; let province_name_en: String?; let former_names: [String]
    }
    static func provinces(_ req: Request) async throws -> DataListResponse<Province> {
        let rows = try await req.db.sql().raw("""
            SELECT p.province_code, p.province_name, p.province_name_en,
              ARRAY(SELECT DISTINCT f.former_province FROM vn_ward_former_names f
                    JOIN vn_wards w ON w.id = f.ward_id
                    WHERE w.province_code = p.province_code AND f.former_province <> p.province_name
                    ORDER BY 1) AS former_names
            FROM (SELECT DISTINCT province_code, province_name, province_name_en FROM vn_wards) p
            ORDER BY p.province_name
            """).all(decoding: ProvinceRow.self)
        return DataListResponse(data: rows.map { row in
            // A province that kept its name is not its own former name; SQL
            // can't tell, the two sources place the tone mark differently
            // ("Khánh Hoà" / "Khánh Hòa").
            let former = row.former_names.filter { PlaceReader.english($0) != PlaceReader.english(row.province_name) }
            return Province(province_code: row.province_code, province_name: row.province_name,
                            province_name_en: row.province_name_en,
                            former_names: former, former_names_en: former.map(PlaceReader.english))
        })
    }

    struct Ward: Content {
        var id: String; var code: String; var name: String
        @NullCoded var name_en: String?; @NullCoded var full_name: String?; @NullCoded var full_name_en: String?
        @NullCoded var unit_type: String?; @NullCoded var lat: Double?; @NullCoded var lng: Double?
        /// "Phường Bến Nghé, Quận 1": each former ward now part of this one.
        var former_names: [String]
        /// The same names in English, in the same order ("Ben Nghe Ward, District 1").
        var former_names_en: [String] = []
    }
    private struct WardRow: Decodable {
        let id: String; let code: String; let name: String
        let name_en: String?; let full_name: String?; let full_name_en: String?
        let unit_type: String?; let lat: Double?; let lng: Double?; let former_names: [String]
    }
    static func list(_ req: Request) async throws -> DataListResponse<Ward> {
        guard let code = try? req.query.get(String.self, at: "province_code") else {
            throw StatusMessageError(.badRequest, "province_code is required")
        }
        let rows = try await req.db.sql().raw("""
            SELECT w.id::text AS id, w.code, w.name, w.name_en, w.full_name, w.full_name_en, w.unit_type, w.lat, w.lng,
              ARRAY(SELECT DISTINCT concat_ws(', ', f.former_name, f.former_district)
                    FROM vn_ward_former_names f WHERE f.ward_id = w.id ORDER BY 1) AS former_names
            FROM vn_wards w WHERE w.province_code = \(bind: code) ORDER BY w.name
            """).all(decoding: WardRow.self)
        return DataListResponse(data: rows.map {
            Ward(id: $0.id, code: $0.code, name: $0.name, name_en: $0.name_en, full_name: $0.full_name,
                 full_name_en: $0.full_name_en, unit_type: $0.unit_type, lat: $0.lat, lng: $0.lng,
                 former_names: $0.former_names, former_names_en: $0.former_names.map(PlaceReader.english))
        })
    }
}
