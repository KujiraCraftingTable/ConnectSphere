import Foundation

/// Hobby-only profile details (migration 062): relationship, languages, education.
enum RelationshipStatus: String, CaseIterable, Identifiable {
    case single, inRelationship = "in_relationship", engaged, married, civilUnion = "civil_union"
    case domesticPartnership = "domestic_partnership", openRelationship = "open_relationship"
    case complicated, separated, divorced, widowed

    var id: String { rawValue }

    /// Localizable.strings key.
    var label: String {
        switch self {
        case .single: "Single"
        case .inRelationship: "In a relationship"
        case .engaged: "Engaged"
        case .married: "Married"
        case .civilUnion: "In a civil union"
        case .domesticPartnership: "In a domestic partnership"
        case .openRelationship: "In an open relationship"
        case .complicated: "It's complicated"
        case .separated: "Separated"
        case .divorced: "Divorced"
        case .widowed: "Widowed"
        }
    }
}

/// Languages are stored as ISO codes and shown in the app's language.
enum ProfileLanguages {
    static let codes = [
        "vi", "en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "th", "id", "ms", "tl",
        "km", "lo", "my", "hi", "bn", "ar", "tr", "nl", "sv", "no", "da", "fi", "pl", "cs", "uk",
        "el", "he", "fa", "ur", "ta", "ne", "si", "mn", "hu", "ro",
    ]

    static func name(_ code: String, locale: Locale) -> String {
        locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }
}

/// A school on a Hobby profile.
struct Education: Identifiable, Decodable, Hashable {
    let id: String
    let schoolName: String
    let schoolType: SchoolType
    let major: String?
    let startYear: Int?
    let endYear: Int?

    enum SchoolType: String, CaseIterable, Decodable {
        case university, college, highSchool = "high_school", other
        var label: String {
            switch self {
            case .university: "University"
            case .college: "College"
            case .highSchool: "High school"
            case .other: "Other"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, major
        case schoolName = "school_name"
        case schoolType = "school_type"
        case startYear = "start_year"
        case endYear = "end_year"
    }

    /// "2020 – 2024", "From 2022", "Class of 2026", or nil.
    func yearsText(loc: (String) -> String) -> String? {
        switch (startYear, endYear) {
        case let (s?, e?): return "\(s) – \(e)"
        case let (s?, nil): return String(format: loc("From %@"), String(s))
        case let (nil, e?): return String(format: loc("Class of %@"), String(e))
        default: return nil
        }
    }
}

/// The built-in school list the picker searches (Vietnamese universities and
/// colleges); anything else, a high school, is typed in.
enum SchoolCatalog {
    /// Lowercased, accents and đ folded: "Đại học Bách khoa" ~ "dai hoc bach khoa".
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Up to `limit` schools containing every typed word.
    static func search(_ query: String, limit: Int = 8) -> [String] {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return Array(schools.filter { name in
            let n = fold(name)
            return words.allSatisfy { n.contains($0) }
        }.prefix(limit))
    }

    static let schools = [
        // Hà Nội
        "Đại học Quốc gia Hà Nội", "Trường Đại học Khoa học Tự nhiên – ĐHQG Hà Nội",
        "Trường Đại học Khoa học Xã hội và Nhân văn – ĐHQG Hà Nội", "Trường Đại học Ngoại ngữ – ĐHQG Hà Nội",
        "Trường Đại học Công nghệ – ĐHQG Hà Nội", "Trường Đại học Kinh tế – ĐHQG Hà Nội",
        "Trường Đại học Giáo dục – ĐHQG Hà Nội", "Trường Đại học Việt Nhật – ĐHQG Hà Nội",
        "Đại học Bách khoa Hà Nội", "Trường Đại học Kinh tế Quốc dân", "Trường Đại học Ngoại thương",
        "Học viện Ngoại giao", "Học viện Tài chính", "Học viện Ngân hàng", "Trường Đại học Thương mại",
        "Trường Đại học Luật Hà Nội", "Trường Đại học Y Hà Nội", "Trường Đại học Dược Hà Nội",
        "Trường Đại học Sư phạm Hà Nội", "Trường Đại học Hà Nội", "Trường Đại học Xây dựng Hà Nội",
        "Trường Đại học Giao thông Vận tải", "Trường Đại học Thủy lợi", "Trường Đại học Mỏ – Địa chất",
        "Học viện Công nghệ Bưu chính Viễn thông", "Học viện Báo chí và Tuyên truyền",
        "Trường Đại học Kiến trúc Hà Nội", "Trường Đại học Mỹ thuật Công nghiệp", "Học viện Âm nhạc Quốc gia Việt Nam",
        "Trường Đại học Sân khấu – Điện ảnh Hà Nội", "Học viện Nông nghiệp Việt Nam", "Trường Đại học Công nghiệp Hà Nội",
        "Trường Đại học Điện lực", "Trường Đại học Lao động – Xã hội", "Trường Đại học Văn hóa Hà Nội",
        "Trường Đại học Thăng Long", "Trường Đại học Phenikaa", "Trường Đại học Đại Nam",
        "Trường Đại học FPT", "Trường Đại học VinUni", "Trường Đại học Anh Quốc Việt Nam (BUV)",
        "Học viện Kỹ thuật Quân sự", "Học viện An ninh Nhân dân", "Học viện Cảnh sát Nhân dân",
        // TP. Hồ Chí Minh
        "Đại học Quốc gia TP. Hồ Chí Minh", "Trường Đại học Bách khoa – ĐHQG TP.HCM",
        "Trường Đại học Khoa học Tự nhiên – ĐHQG TP.HCM", "Trường Đại học Khoa học Xã hội và Nhân văn – ĐHQG TP.HCM",
        "Trường Đại học Quốc tế – ĐHQG TP.HCM", "Trường Đại học Công nghệ Thông tin – ĐHQG TP.HCM",
        "Trường Đại học Kinh tế – Luật – ĐHQG TP.HCM", "Đại học Kinh tế TP. Hồ Chí Minh (UEH)",
        "Trường Đại học Ngân hàng TP. Hồ Chí Minh", "Trường Đại học Luật TP. Hồ Chí Minh",
        "Trường Đại học Y Dược TP. Hồ Chí Minh", "Trường Đại học Y khoa Phạm Ngọc Thạch",
        "Trường Đại học Sư phạm TP. Hồ Chí Minh", "Trường Đại học Sư phạm Kỹ thuật TP. Hồ Chí Minh",
        "Trường Đại học Kiến trúc TP. Hồ Chí Minh", "Trường Đại học Giao thông Vận tải TP. Hồ Chí Minh",
        "Trường Đại học Tài chính – Marketing", "Trường Đại học Công nghiệp TP. Hồ Chí Minh",
        "Trường Đại học Nông Lâm TP. Hồ Chí Minh", "Trường Đại học Mở TP. Hồ Chí Minh",
        "Trường Đại học Sài Gòn", "Trường Đại học Tôn Đức Thắng", "Trường Đại học Văn Lang",
        "Trường Đại học Hoa Sen", "Trường Đại học Nguyễn Tất Thành", "Trường Đại học Công nghệ TP. Hồ Chí Minh (HUTECH)",
        "Trường Đại học Hồng Bàng Quốc tế", "Trường Đại học Kinh tế – Tài chính TP. Hồ Chí Minh (UEF)",
        "Trường Đại học Quốc tế Sài Gòn", "Trường Đại học Văn Hiến", "Trường Đại học Gia Định",
        "Trường Đại học RMIT Việt Nam", "Trường Đại học Fulbright Việt Nam", "Trường Đại học Mỹ thuật TP. Hồ Chí Minh",
        "Nhạc viện TP. Hồ Chí Minh",
        // Miền Trung & Tây Nguyên
        "Đại học Đà Nẵng", "Trường Đại học Bách khoa – Đại học Đà Nẵng", "Trường Đại học Kinh tế – Đại học Đà Nẵng",
        "Trường Đại học Sư phạm – Đại học Đà Nẵng", "Trường Đại học Ngoại ngữ – Đại học Đà Nẵng",
        "Trường Đại học Duy Tân", "Trường Đại học Đông Á", "Đại học Huế", "Trường Đại học Y Dược – Đại học Huế",
        "Trường Đại học Khoa học – Đại học Huế", "Trường Đại học Sư phạm – Đại học Huế", "Trường Đại học Vinh",
        "Trường Đại học Quy Nhơn", "Trường Đại học Nha Trang", "Trường Đại học Tây Nguyên", "Trường Đại học Đà Lạt",
        // Miền Bắc khác & Miền Nam khác
        "Đại học Thái Nguyên", "Trường Đại học Hàng hải Việt Nam", "Trường Đại học Hải Phòng",
        "Trường Đại học Hồng Đức", "Trường Đại học Cần Thơ", "Trường Đại học Y Dược Cần Thơ",
        "Trường Đại học An Giang", "Trường Đại học Trà Vinh", "Trường Đại học Đồng Tháp",
        "Trường Đại học Thủ Dầu Một", "Trường Đại học Lạc Hồng", "Trường Đại học Bà Rịa – Vũng Tàu",
        // Quốc tế / liên kết
        "Đại học Greenwich (Việt Nam)", "Trường Đại học Swinburne Việt Nam", "Trường Đại học Việt Đức",
        "Trường Đại học Khoa học và Công nghệ Hà Nội (USTH)",
        // Cao đẳng
        "Cao đẳng FPT Polytechnic", "Trường Cao đẳng Kỹ thuật Cao Thắng", "Trường Cao đẳng Công nghệ Thủ Đức",
        "Trường Cao đẳng Kinh tế Đối ngoại", "Trường Cao đẳng Du lịch Hà Nội", "Trường Cao đẳng Sư phạm Trung ương",
    ]
}
