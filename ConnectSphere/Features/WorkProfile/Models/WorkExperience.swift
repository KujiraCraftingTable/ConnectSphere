import Foundation

/// One role in someone's work history (Work mode).
struct WorkExperience: Identifiable, Decodable, Hashable {
    let id: String
    var companyId: String?
    var companyName: String
    var companyLogoUrl: String?
    var companyVerified: Bool
    var title: String
    var employmentType: EmploymentKind
    var location: String?
    var locationType: LocationKind?
    /// "YYYY-MM".
    var startMonth: String
    /// "YYYY-MM"; nil while it's the current role.
    var endMonth: String?
    var description: String?

    var isCurrent: Bool { endMonth == nil }

    // MARK: - Kinds
    enum EmploymentKind: String, Decodable, CaseIterable, Hashable {
        case fullTime = "full_time", partTime = "part_time", internship, contract, freelance
        case selfEmployed = "self_employed"
        var label: String {
            switch self {
            case .fullTime: "Full-time"
            case .partTime: "Part-time"
            case .internship: "Internship"
            case .contract: "Contract"
            case .freelance: "Freelance"
            case .selfEmployed: "Self-employed"
            }
        }
    }

    enum LocationKind: String, Decodable, CaseIterable, Hashable {
        case onsite, hybrid, remote
        var label: String {
            switch self {
            case .onsite: "On-site"
            case .hybrid: "Hybrid"
            case .remote: "Remote"
            }
        }
    }

    // MARK: - Grouping
    /// Roles at one company together: the page (or name), and the time there.
    struct Group: Identifiable, Hashable {
        let id: String
        let companyId: String?
        let companyName: String
        let logoUrl: String?
        let verified: Bool
        let roles: [WorkExperience]
        /// Earliest start to latest end (or now).
        var totalMonths: Int {
            let starts = roles.compactMap { WorkMonth($0.startMonth) }
            guard let first = starts.min() else { return 0 }
            let last = roles.contains(where: \.isCurrent) ? WorkMonth.now
                : roles.compactMap { $0.endMonth.flatMap(WorkMonth.init) }.max() ?? first
            return WorkMonth.span(from: first, to: last)
        }
    }

    /// Roles at the same company are grouped. By page, or by name when not
    /// linked, in the order the list already has (current, then recent).
    static func grouped(_ roles: [WorkExperience]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [WorkExperience]] = [:]
        for role in roles {
            let key = role.companyId ?? "name:" + role.companyName.lowercased()
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(role)
        }
        return order.map { key in
            let roles = byKey[key]!
            let lead = roles[0]
            return Group(id: key, companyId: lead.companyId, companyName: lead.companyName,
                         logoUrl: lead.companyLogoUrl, verified: lead.companyVerified, roles: roles)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, location, description
        case companyId = "company_id"
        case companyName = "company_name"
        case companyLogoUrl = "company_logo_url"
        case companyVerified = "company_verified"
        case employmentType = "employment_type"
        case locationType = "location_type"
        case startMonth = "start_month"
        case endMonth = "end_month"
    }
}

// MARK: - Month
/// A calendar month ("2024-03"), for durations like "2 yrs 3 mos".
struct WorkMonth: Comparable, Hashable {
    let year: Int
    let month: Int

    init?(_ s: String) {
        let parts = s.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        year = y
        month = m
    }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    static var now: WorkMonth {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return WorkMonth(year: c.year!, month: c.month!)
    }

    var key: String { String(format: "%04d-%02d", year, month) }

    static func < (a: WorkMonth, b: WorkMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }

    /// Months worked, counting both ends: Mar → Mar is 1 month, Jan → Dec is 12.
    static func span(from a: WorkMonth, to b: WorkMonth) -> Int {
        max(1, (b.year - a.year) * 12 + (b.month - a.month) + 1)
    }

    /// "2 yrs 3 mos", "1 yr", "5 mos" (English and Vietnamese via `loc`).
    static func duration(_ months: Int, loc: (String) -> String) -> String {
        let years = months / 12, rest = months % 12
        var parts: [String] = []
        if years > 0 { parts.append(String(format: loc(years == 1 ? "%lld yr" : "%lld yrs"), years)) }
        if rest > 0 || years == 0 { parts.append(String(format: loc(rest == 1 ? "%lld mo" : "%lld mos"), max(rest, 1))) }
        return parts.joined(separator: " ")
    }

    /// "Mar 2024".
    func label(locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMM yyyy")
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))!
        return f.string(from: date)
    }
}

// MARK: - Bundle locale
extension Bundle {
    /// The locale matching the app language this bundle was loaded for
    /// (`vi.lproj` → Vietnamese), for dates like "Mar 2024" / "thg 3 2024".
    var locale: Locale {
        Locale(identifier: bundlePath.hasSuffix("vi.lproj") ? "vi_VN" : "en_US")
    }
}
