import Foundation

/// Who may use Dating and who may meet whom (migration 081). Pure, so the
/// rules can be tested without a database; `DatingStore`'s SQL applies the
/// same rules in the browse query and must stay in step with them.
enum DatingRules {
    static let minAge = SearchController.datingMinAge
    static let adultAge = 18
    static let maxPhotos = 6
    static let maxBio = 500
    static let maxCity = 200
    static let ages = 16...99
    static let distancesKm = 1...500
    static let heightsCm = 100...250
    static let interests: Set<String> = ["men", "women", "everyone"]
    static let kidsAnswers: Set<String> = ["no", "yes", "prefer_not"]

    /// 16–17 and 18+ never see each other, whatever age range either picks.
    enum Band: String, Codable { case teen, adult }

    /// nil = locked: under 16, or no age on the account (an unknown age is
    /// never assumed to be old enough).
    static func band(age: Int?) -> Band? {
        guard let age, age >= minAge else { return nil }
        return age < adultAge ? .teen : .adult
    }

    /// The age range someone can actually be shown, after the band is applied.
    static func effectiveRange(band: Band, min: Int, max: Int) -> ClosedRange<Int>? {
        let bandRange = band == .teen ? minAge...(adultAge - 1) : adultAge...ages.upperBound
        let lo = Swift.max(min, bandRange.lowerBound), hi = Swift.min(max, bandRange.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    /// `users.gender` is male / female / other; "other" only shows to "everyone".
    static func wants(_ interestedIn: String, gender: String) -> Bool {
        switch interestedIn {
        case "men": return gender == "male"
        case "women": return gender == "female"
        default: return true
        }
    }

    struct Person {
        var age: Int?
        var gender: String
        var interestedIn: String
        var minAge: Int
        var maxAge: Int
        var maxDistanceKm: Int?
        var latitude: Double
        var longitude: Double
    }

    /// Whether `a` and `b` may be shown to each other: both 16+, the same band,
    /// each wanted by the other's gender and age choices, and within both
    /// people's distance limits.
    static func isFit(_ a: Person, _ b: Person) -> Bool {
        guard let bandA = band(age: a.age), let bandB = band(age: b.age), bandA == bandB,
              let ageA = a.age, let ageB = b.age,
              let rangeA = effectiveRange(band: bandA, min: a.minAge, max: a.maxAge),
              let rangeB = effectiveRange(band: bandB, min: b.minAge, max: b.maxAge),
              rangeA.contains(ageB), rangeB.contains(ageA),
              wants(a.interestedIn, gender: b.gender), wants(b.interestedIn, gender: a.gender) else { return false }
        let km = distanceKm(a.latitude, a.longitude, b.latitude, b.longitude)
        return km <= Double(a.maxDistanceKm ?? .max) && km <= Double(b.maxDistanceKm ?? .max)
    }

    /// Great-circle distance; the SQL in `DatingStore.distanceSQL` is the same formula.
    static func distanceKm(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// A match row stores the pair in a fixed order so it exists only once.
    /// Lowercased UUID text sorts the same way Postgres orders `uuid`.
    static func pair(_ x: String, _ y: String) -> (a: String, b: String) {
        let lx = x.lowercased(), ly = y.lowercased()
        return lx < ly ? (lx, ly) : (ly, lx)
    }

    /// A like makes a match only when the other person already liked back.
    static func makesMatch(liked: Bool, theyLikedMe: Bool) -> Bool { liked && theyLikedMe }

    struct ProfileInput {
        var bio: String
        var interestedIn: String
        var minAge: Int
        var maxAge: Int
        var maxDistanceKm: Int?
        var heightCm: Int?
        var hasKids: String?
        var city: String
        var latitude: Double
        var longitude: Double
        var photos: [String]
    }

    /// A dating location is the phone's position, named by its district and city.
    static func locationProblem(city: String, latitude: Double, longitude: Double) -> String? {
        if city.isEmpty || city.count > maxCity { return "Share your location to use Dating" }
        if !(-90...90).contains(latitude) || !(-180...180).contains(longitude) { return "Share your location to use Dating" }
        return nil
    }

    /// The reason a profile can't be saved, or nil when it's fine.
    static func problem(with p: ProfileInput) -> String? {
        if p.bio.count > maxBio { return "Your bio can be up to \(maxBio) characters" }
        if !interests.contains(p.interestedIn) { return "interested_in must be men, women or everyone" }
        if !ages.contains(p.minAge) || !ages.contains(p.maxAge) || p.minAge > p.maxAge {
            return "Choose an age range between \(ages.lowerBound) and \(ages.upperBound)"
        }
        if let d = p.maxDistanceKm, !distancesKm.contains(d) {
            return "Distance must be \(distancesKm.lowerBound)–\(distancesKm.upperBound) km"
        }
        if let h = p.heightCm, !heightsCm.contains(h) {
            return "Height must be \(heightsCm.lowerBound)–\(heightsCm.upperBound) cm"
        }
        if let kids = p.hasKids, !kidsAnswers.contains(kids) { return "has_kids must be no, yes or prefer_not" }
        if let problem = locationProblem(city: p.city, latitude: p.latitude, longitude: p.longitude) { return problem }
        if p.photos.isEmpty || p.photos.count > maxPhotos { return "Add 1–\(maxPhotos) photos" }
        if p.photos.contains(where: { !$0.hasPrefix("/uploads/") }) { return "Photos must be uploaded first" }
        return nil
    }
}
