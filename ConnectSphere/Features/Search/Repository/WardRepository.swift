import Foundation

/// Fetches province and ward data from the backend.
struct WardRepository {
    private let client = NetworkClient.shared

    /// Returns all 34 provinces.
    func fetchProvinces() async throws -> [ProvinceDTO] {
        let response = try await client.fetch(ProvincesResponseDTO.self, from: .listProvinces)
        return response.data
    }

    /// Returns all wards for a given province code.
    func fetchWards(provinceCode: String) async throws -> [WardDTO] {
        let response = try await client.fetch(WardsResponseDTO.self, from: .listWards(provinceCode: provinceCode))
        return response.data
    }
}
