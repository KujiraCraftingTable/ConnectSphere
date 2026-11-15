import Foundation

struct ProvinceDTO: Decodable, Identifiable {
    let province_code: String
    let province_name: String
    let province_name_en: String
    /// Provinces merged into this one in 2025 ("Tỉnh Bình Dương"), and the
    /// same names in English, in the same order ("Binh Duong Province").
    let former_names: [String]?
    let former_names_en: [String]?

    var id: String { province_code }
}

struct ProvincesResponseDTO: Decodable {
    let data: [ProvinceDTO]
}

struct WardDTO: Decodable, Identifiable {
    let id: String
    let code: String
    let name: String
    let name_en: String
    let full_name: String
    let full_name_en: String
    let unit_type: String
    let lat: Double
    let lng: Double
    /// Former wards now part of this one ("Phường Bến Nghé, Quận 1"), and
    /// the same names in English, in the same order ("Ben Nghe Ward, District 1").
    let former_names: [String]?
    let former_names_en: [String]?
}

struct WardsResponseDTO: Decodable {
    let data: [WardDTO]
}
