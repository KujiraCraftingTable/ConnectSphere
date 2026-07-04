import Foundation

struct ProvinceDTO: Decodable, Identifiable {
    let province_code: String
    let province_name: String
    let province_name_en: String

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
}

struct WardsResponseDTO: Decodable {
    let data: [WardDTO]
}
