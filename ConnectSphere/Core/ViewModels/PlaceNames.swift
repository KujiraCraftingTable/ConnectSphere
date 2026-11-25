import Foundation

// MARK: - Place names
/// Place names in the app's language, for places that come from the ward
/// tables rather than from what someone typed:
///   • a person's province, stored in English ("Ho Chi Minh") → "Hồ Chí Minh"
///   • a job's ward and province, stored in Vietnamese ("Phường An Lạc,
///     Thành phố Hồ Chí Minh") → "An Lac Ward, Ho Chi Minh City"
/// Anything else (a listing's or an event's place, typed by its author) is
/// user content and is left as written.
enum PlaceNames {
    /// The 34 provinces by the name `users.location` stores.
    static let vietnameseProvinces: [String: String] = [
        "An Giang": "An Giang", "Bac Ninh": "Bắc Ninh", "Ca Mau": "Cà Mau", "Can Tho": "Cần Thơ",
        "Cao Bang": "Cao Bằng", "Dak Lak": "Đắk Lắk", "Da Nang": "Đà Nẵng", "Dien Bien": "Điện Biên",
        "Dong Nai": "Đồng Nai", "Dong Thap": "Đồng Tháp", "Gia Lai": "Gia Lai", "Hai Phong": "Hải Phòng",
        "Hanoi": "Hà Nội", "Ha Tinh": "Hà Tĩnh", "Ho Chi Minh": "Hồ Chí Minh", "Hue": "Huế",
        "Hung Yen": "Hưng Yên", "Khanh Hoa": "Khánh Hoà", "Lai Chau": "Lai Châu", "Lam Dong": "Lâm Đồng",
        "Lang Son": "Lạng Sơn", "Lao Cai": "Lào Cai", "Nghe An": "Nghệ An", "Ninh Binh": "Ninh Bình",
        "Phu Tho": "Phú Thọ", "Quang Ngai": "Quảng Ngãi", "Quang Ninh": "Quảng Ninh", "Quang Tri": "Quảng Trị",
        "Son La": "Sơn La", "Tay Ninh": "Tây Ninh", "Thai Nguyen": "Thái Nguyên", "Thanh Hoa": "Thanh Hoá",
        "Tuyen Quang": "Tuyên Quang", "Vinh Long": "Vĩnh Long",
    ]

    /// A person's province in the app's language. A value that isn't one of
    /// the 34 (an old free-text location) is shown as stored.
    static func province(_ stored: String, vietnamese: Bool) -> String {
        vietnamese ? (vietnameseProvinces[stored] ?? stored) : stored
    }

    /// The unit kinds, in the style of the ward table's English names.
    private static let kinds: [(vietnamese: String, english: String)] = [
        ("thành phố", "City"), ("thị xã", "Town"), ("thị trấn", "Township"),
        ("đặc khu", "Special administrative region"),
        ("phường", "Ward"), ("xã", "Commune"), ("quận", "District"), ("huyện", "District"), ("tỉnh", "Province"),
    ]

    /// A ward-and-province address in the app's language. Only an address
    /// made of administrative units is translated ("Phường An Lạc, Thành phố
    /// Hồ Chí Minh"); a typed one ("Tầng 5, toà nhà ABC") is left alone, as
    /// stripping its accents would not be a translation.
    static func address(_ stored: String, vietnamese: Bool) -> String {
        guard !vietnamese else { return stored }
        let parts = stored.components(separatedBy: ", ")
        let translated = parts.compactMap(englishUnit)
        return translated.count == parts.count ? translated.joined(separator: ", ") : stored
    }

    /// "Phường An Lạc" → "An Lac Ward", "Quận 1" → "District 1"; nil when the
    /// part doesn't start with a unit kind.
    private static func englishUnit(_ part: String) -> String? {
        let lower = part.precomposedStringWithCanonicalMapping.lowercased()
        for kind in kinds {
            let prefix = kind.vietnamese.precomposedStringWithCanonicalMapping + " "
            guard lower.hasPrefix(prefix) else { continue }
            let name = String(part.precomposedStringWithCanonicalMapping.dropFirst(prefix.count))
            guard !name.isEmpty else { return nil }
            if name.allSatisfy(\.isNumber) { return "\(kind.english) \(name)" }
            let plain = name.folding(options: .diacriticInsensitive, locale: nil)
                .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            return "\(plain) \(kind.english)"
        }
        return nil
    }
}

// MARK: - Bundle helpers
extension Bundle {
    /// A person's province in this bundle's language (`PlaceNames.province`).
    func province(_ stored: String) -> String { PlaceNames.province(stored, vietnamese: isVietnamese) }
    /// A ward-and-province address in this bundle's language (`PlaceNames.address`).
    func address(_ stored: String) -> String { PlaceNames.address(stored, vietnamese: isVietnamese) }
}
