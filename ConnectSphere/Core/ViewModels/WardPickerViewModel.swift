import Foundation
import Observation

/// Data for the two-level Province → Ward picker.
@MainActor
@Observable
final class WardPickerViewModel {
    private(set) var provinces: [ProvinceDTO] = []
    private(set) var wards: [WardDTO] = []
    private(set) var isLoadingProvinces = false
    private(set) var isLoadingWards = false

    private let repository = WardRepository()

    func provinceName(code: String?) -> String? {
        provinces.first { $0.province_code == code }?.province_name
    }

    func wardName(id: String?) -> String? {
        wards.first { $0.id == id }?.full_name
    }

    /// Loads provinces once; with a province already chosen (editing), its
    /// wards are loaded too.
    func loadProvinces(selectedProvinceCode: String?) async {
        guard provinces.isEmpty else { return }
        isLoadingProvinces = true
        if let fetched = try? await repository.fetchProvinces() { provinces = fetched }
        isLoadingProvinces = false
        if let selectedProvinceCode { await loadWards(provinceCode: selectedProvinceCode) }
    }

    func loadWards(provinceCode: String) async {
        isLoadingWards = true
        wards = []
        if let fetched = try? await repository.fetchWards(provinceCode: provinceCode) { wards = fetched }
        isLoadingWards = false
    }
}
