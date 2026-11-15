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

    // Every name is shown in the app's language: "Thành phố Hồ Chí Minh" /
    // "Ho Chi Minh City", "Phường Sài Gòn" / "Sai Gon Ward". Search matches
    // either language, with or without accents.

    func name(of province: ProvinceDTO, vietnamese: Bool) -> String {
        vietnamese ? province.province_name : province.province_name_en
    }

    func name(of ward: WardDTO, vietnamese: Bool) -> String {
        vietnamese ? ward.full_name : ward.full_name_en
    }

    func provinceName(code: String?, vietnamese: Bool) -> String? {
        provinces.first { $0.province_code == code }.map { name(of: $0, vietnamese: vietnamese) }
    }

    func wardName(id: String?, vietnamese: Bool) -> String? {
        wards.first { $0.id == id }.map { name(of: $0, vietnamese: vietnamese) }
    }

    /// Wards whose name contains the query ("sai gon" finds "Phường Sài
    /// Gòn"), or that a former ward of that name is now part of ("ben nghe"
    /// finds it too), in the order of the names shown.
    func wards(matching query: String, vietnamese: Bool) -> [WardDTO] {
        let q = Self.folded(query.trimmingCharacters(in: .whitespaces))
        let found = q.isEmpty ? wards : wards.filter {
            Self.ownNameMatches($0.full_name, $0.full_name_en, q)
                || !Self.formerMatches($0.former_names, $0.former_names_en, q).isEmpty
        }
        return found.sorted {
            name(of: $0, vietnamese: vietnamese).localizedStandardCompare(name(of: $1, vietnamese: vietnamese)) == .orderedAscending
        }
    }

    /// Same search for provinces ("ho chi minh" finds "Thành phố Hồ Chí
    /// Minh", and so does "binh duong", merged into it in 2025).
    func provinces(matching query: String, vietnamese: Bool) -> [ProvinceDTO] {
        let q = Self.folded(query.trimmingCharacters(in: .whitespaces))
        let found = q.isEmpty ? provinces : provinces.filter {
            Self.ownNameMatches($0.province_name, $0.province_name_en, q)
                || !Self.formerMatches($0.former_names, $0.former_names_en, q).isEmpty
        }
        return found.sorted {
            name(of: $0, vietnamese: vietnamese).localizedStandardCompare(name(of: $1, vietnamese: vietnamese)) == .orderedAscending
        }
    }

    /// The former names that made a ward match, to show under it, so someone
    /// who typed an old name sees why today's ward came up. nil when its own
    /// name matched or nothing is typed.
    func formerNames(of ward: WardDTO, matching query: String, vietnamese: Bool) -> String? {
        let q = Self.folded(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, !Self.ownNameMatches(ward.full_name, ward.full_name_en, q) else { return nil }
        return Self.shown(Self.formerMatches(ward.former_names, ward.former_names_en, q), vietnamese: vietnamese)
    }

    func formerNames(of province: ProvinceDTO, matching query: String, vietnamese: Bool) -> String? {
        let q = Self.folded(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, !Self.ownNameMatches(province.province_name, province.province_name_en, q) else { return nil }
        return Self.shown(Self.formerMatches(province.former_names, province.former_names_en, q), vietnamese: vietnamese)
    }

    private static func ownNameMatches(_ vietnamese: String, _ english: String, _ foldedQuery: String) -> Bool {
        contains(folded(vietnamese), foldedQuery) || contains(folded(english), foldedQuery)
    }

    /// The former names matching in either language, as (Vietnamese, English)
    /// pairs. The two lists arrive in the same order.
    private static func formerMatches(_ vietnamese: [String]?, _ english: [String]?,
                                      _ foldedQuery: String) -> [(vi: String, en: String)] {
        let vi = vietnamese ?? [], en = english ?? []
        return vi.indices.compactMap { i in
            let pair = (vi: vi[i], en: i < en.count ? en[i] : vi[i])
            return contains(folded(pair.vi), foldedQuery) || contains(folded(pair.en), foldedQuery) ? pair : nil
        }
    }

    /// At most three names: a former district can match a dozen wards' worth.
    private static func shown(_ names: [(vi: String, en: String)], vietnamese: Bool) -> String? {
        names.isEmpty ? nil : names.prefix(3).map { vietnamese ? $0.vi : $0.en }.joined(separator: "; ")
    }

    /// `text` contains `query`, except that a query ending in a digit must
    /// not stop in the middle of a number: "quan 1" is not "Quận 10".
    private static func contains(_ text: String, _ query: String) -> Bool {
        guard query.last?.isNumber == true else { return text.contains(query) }
        var from = text.startIndex
        while let r = text.range(of: query, range: from..<text.endIndex) {
            if r.upperBound == text.endIndex || !text[r.upperBound].isNumber { return true }
            from = r.upperBound
        }
        return false
    }

    /// "đ" isn't a diacritic to Foundation, so it is mapped by hand.
    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
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
