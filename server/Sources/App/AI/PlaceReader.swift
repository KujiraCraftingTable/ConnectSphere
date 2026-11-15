import Vapor
import SQLKit
import AsyncHTTPClient

/// Reads Vietnamese place names out of free text (a post, a search prompt) as
/// today's wards. It knows today's wards and provinces (`vn_wards`) and what
/// they were called before the 1 July 2025 merger (`vn_ward_former_names`,
/// migration 146), so "Phường Bến Nghé, Quận 1" reads as Phường Sài Gòn and
/// a bare "Quận 1" as every ward formed from it.
///
/// Two ways of reading:
///   • whole text (`read`): a ward or district counts only with its kind in
///     front ("Phường", "P.", "Quận", "Q." …), because many names are everyday
///     words ("Thành Công", "Bình Minh")
///   • a phrase already known to be a place (`read(…, bare: true)`, what the
///     LLM pulled out of a prompt or a post): names count on their own, the
///     way people write them ("bình thạnh", "ben nghe q1"). A name that is
///     both a former district and a ward means the district, the wider one.
/// In both, a name found in several provinces needs its district or province
/// in the text, or falls back to `homeProvince` (the searcher's or author's
/// own); failing that it is skipped. "Hòa" and "Hoà" are one spelling;
/// unaccented text matches names of two or more words, and numbers.
/// A street address ("45 Lê Thánh Tôn") is not read here: `street` is set and
/// `resolve` asks the geocoder.
enum PlaceReader {
    struct Places: Equatable, Sendable {
        /// `vn_wards.id` (lowercased) of every ward the text names.
        var wardIDs: Set<String> = []
        /// `vn_wards.province_code` of every province the text names.
        var provinceCodes: Set<String> = []
        /// The phrase holds a street or house number, which only a geocoder can place.
        var street = false
        /// The address itself, without the words around it ("45 lê thánh tôn").
        var streetText: String?
        /// What was read, in the gazetteer's own spelling ("Quận Bình Thạnh",
        /// "Phường Bến Nghé, Quận 1"), to show the searcher how a typed
        /// "binh thanh" was understood.
        var labels: [String] = []
        var isEmpty: Bool { wardIDs.isEmpty && provinceCodes.isEmpty }
    }

    struct WardRow: Decodable, Sendable {
        let id: String; let name: String; let province_code: String; let province_name: String
        var full_name: String? = nil
    }
    struct FormerRow: Decodable, Sendable {
        let ward_id: String; let province_code: String
        let former_name: String?; let former_district: String; let former_province: String
    }

    // MARK: Spelling

    private static let toneMarks: Set<Unicode.Scalar> = ["\u{0300}", "\u{0301}", "\u{0303}", "\u{0309}", "\u{0323}"]

    /// One word, lowercased, with its tone mark moved to the end, so the two
    /// accepted placements ("hòa", "hoà") compare equal while different tones
    /// and vowels stay different.
    static func key(_ word: String) -> String {
        var base = String.UnicodeScalarView(), tone = String.UnicodeScalarView()
        for s in word.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if toneMarks.contains(s) { tone.append(s) } else { base.append(s) }
        }
        return String(base).precomposedStringWithCanonicalMapping + String(tone)
    }

    /// One word with every accent removed ("bến" → "ben", "đ" → "d").
    static func plain(_ word: String) -> String {
        String(word.lowercased().replacingOccurrences(of: "đ", with: "d")
            .decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !$0.properties.isDiacritic && $0.properties.canonicalCombiningClass == .notReordered })
    }

    /// Words of `s`: runs of letters and digits. "Q1" and "P12" split into the
    /// kind and the number.
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).flatMap { w -> [String] in
            let lower = w.lowercased()
            if let first = lower.first, "qp".contains(first), lower.count > 1, lower.dropFirst().allSatisfy(\.isNumber) {
                return [String(first), String(lower.dropFirst())]
            }
            return [String(w)]
        }
    }

    private static func phrase(_ ws: [String], _ f: (String) -> String) -> String { ws.map(f).joined(separator: " ") }

    // MARK: Kinds ("Phường", "Quận", "Tỉnh")

    private enum Kind { case ward, district, province, city }
    /// The kind words, accented and typed without accents. "Thành phố" may be
    /// a province (Hồ Chí Minh) or a former district (Thủ Đức).
    private static let kinds: [(words: [String], kind: Kind)] = {
        let typed: [(String, Kind)] = [
            ("thành phố", .city), ("thanh pho", .city), ("tp", .city),
            ("thị xã", .district), ("thi xa", .district), ("tx", .district),
            ("thị trấn", .ward), ("thi tran", .ward), ("tt", .ward),
            ("đặc khu", .ward), ("dac khu", .ward),
            ("phường", .ward), ("phuong", .ward), ("p", .ward), ("xã", .ward), ("xa", .ward),
            ("quận", .district), ("quan", .district), ("q", .district),
            ("huyện", .district), ("huyen", .district),
            ("tỉnh", .province), ("tinh", .province),
            ("district", .district), ("ward", .ward),
        ]
        return typed.map { (words: $0.0.split(separator: " ").map { key(String($0)) }, kind: $0.1) }
    }()

    /// "Phường Bến Nghé" → "Bến Nghé". A name with no kind in front is kept whole.
    static func bareName(_ full: String) -> [String] {
        let ws = words(full)
        let keys = ws.map(key)
        for k in kinds where keys.count > k.words.count && Array(keys.prefix(k.words.count)) == k.words {
            return Array(ws.dropFirst(k.words.count))
        }
        return ws
    }

    // MARK: English names

    /// The kind words in English, in the style of `vn_wards.full_name_en`
    /// ("Sai Gon Ward", "Ho Chi Minh City").
    private static let englishKinds: [(words: [String], english: String)] = [
        ("thành phố", "City"), ("thị xã", "Town"), ("thị trấn", "Township"),
        ("đặc khu", "Special administrative region"),
        ("phường", "Ward"), ("xã", "Commune"), ("quận", "District"), ("huyện", "District"), ("tỉnh", "Province"),
    ].map { (words: $0.0.split(separator: " ").map { key(String($0)) }, english: $0.1) }

    /// A Vietnamese unit name in English: "Phường Bến Nghé, Quận 1" →
    /// "Ben Nghe Ward, District 1". The former names (migration 146) come
    /// in Vietnamese only, so the kind is translated and the name written
    /// without accents, the way `vn_wards` spells today's names in English.
    /// A numbered unit keeps its kind in front ("Ward 12").
    static func english(_ name: String) -> String {
        name.components(separatedBy: ", ").map { part -> String in
            let ws = part.split(separator: " ").map(String.init)
            let keys = ws.map(key)
            let plainName: ([String]) -> String = { words in
                words.map { $0.folding(options: .diacriticInsensitive, locale: nil)
                    .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D") }
                    .joined(separator: " ")
            }
            for k in englishKinds where keys.count > k.words.count && Array(keys.prefix(k.words.count)) == k.words {
                let rest = Array(ws.dropFirst(k.words.count))
                let numbered = rest.count == 1 && rest[0].allSatisfy(\.isNumber)
                return numbered ? "\(k.english) \(rest[0])" : "\(plainName(rest)) \(k.english)"
            }
            return plainName(ws)
        }.joined(separator: ", ")
    }

    // MARK: Gazetteer

    /// One place a name can mean.
    struct Unit: Sendable {
        var wardIDs: Set<String>
        var provinces: Set<String>
        /// Former district and province (spelling keys, no kind), nil for today's wards.
        var district: String?
        var formerProvince: String?
        /// A whole former district rather than one ward.
        var isDistrict = false
        /// The name as stored, with its kind.
        var label = ""
        var isCurrent: Bool { district == nil }
    }

    struct Gazetteer: Sendable {
        /// Name → places, by exact spelling key and by unaccented spelling.
        struct Index: Sendable {
            var exact: [String: [Unit]] = [:]
            var loose: [String: [Unit]] = [:]
            var longest = 1
            mutating func add(_ name: [String], _ unit: Unit) {
                guard !name.isEmpty else { return }
                exact[PlaceReader.phrase(name, PlaceReader.key), default: []].append(unit)
                loose[PlaceReader.phrase(name, PlaceReader.plain), default: []].append(unit)
                longest = max(longest, name.count)
            }
        }
        var wards = Index(), districts = Index(), provinces = Index()
        /// Province code → its name as stored ("Thành phố Hồ Chí Minh").
        var provinceNameByCode: [String: String] = [:]

        /// "Hòa Bình" is also the word for peace and "Thái Bình" starts the
        /// Pacific ("Thái Bình Dương"): they need "Tỉnh" in front. Unaccented.
        static let provincesNeedingKind: Set<String> = ["hoa binh", "thai binh"]
        static let provinceAliases: [(alias: String, name: String)] = [
            ("hcm", "Hồ Chí Minh"), ("tphcm", "Hồ Chí Minh"), ("hn", "Hà Nội"),
            // On its own "Sài Gòn" is the city; the ward needs "Phường" in front.
            ("sài gòn", "Hồ Chí Minh"), ("saigon", "Hồ Chí Minh"), ("sg", "Hồ Chí Minh"),
        ]

        init(wards rows: [WardRow], former: [FormerRow]) {
            var provinceCodes: [String: Set<String>] = [:]      // bare province name key → codes
            var provinceNames: [String: [String]] = [:]         // key → words
            var provinceLabels: [String: String] = [:]
            func province(_ full: String, _ code: String) {
                let bare = PlaceReader.bareName(full)
                let k = PlaceReader.phrase(bare, PlaceReader.key)
                provinceCodes[k, default: []].insert(code)
                provinceNames[k] = bare
                provinceLabels[k] = full
            }
            for w in rows {
                wards.add(PlaceReader.words(w.name),
                          Unit(wardIDs: [w.id.lowercased()], provinces: [w.province_code], label: w.full_name ?? w.name))
                province(w.province_name, w.province_code)
                provinceNameByCode[w.province_code] = w.province_name
            }
            struct FormerKey: Hashable { let name: String; let district: String; let province: String }
            var formerWards: [FormerKey: Unit] = [:], formerNames: [FormerKey: [String]] = [:]
            var formerDistricts: [FormerKey: Unit] = [:], districtNames: [FormerKey: [String]] = [:]
            for f in former {
                let district = PlaceReader.bareName(f.former_district)
                let dKey = PlaceReader.phrase(district, PlaceReader.key)
                let pKey = PlaceReader.phrase(PlaceReader.bareName(f.former_province), PlaceReader.key)
                province(f.former_province, f.province_code)
                let id = f.ward_id.lowercased()
                let dk = FormerKey(name: "", district: dKey, province: pKey)
                formerDistricts[dk, default: Unit(wardIDs: [], provinces: [], district: dKey, formerProvince: pKey,
                                                  isDistrict: true, label: f.former_district)].wardIDs.insert(id)
                formerDistricts[dk]?.provinces.insert(f.province_code)
                districtNames[dk] = district
                guard let full = f.former_name else { continue }
                let name = PlaceReader.bareName(full)
                let wk = FormerKey(name: PlaceReader.phrase(name, PlaceReader.key), district: dKey, province: pKey)
                formerWards[wk, default: Unit(wardIDs: [], provinces: [], district: dKey, formerProvince: pKey,
                                              label: "\(full), \(f.former_district)")].wardIDs.insert(id)
                formerWards[wk]?.provinces.insert(f.province_code)
                formerNames[wk] = name
            }
            for (k, u) in formerWards { wards.add(formerNames[k] ?? [], u) }
            for (k, u) in formerDistricts { districts.add(districtNames[k] ?? [], u) }
            for (k, codes) in provinceCodes {
                provinces.add(provinceNames[k] ?? [], Unit(wardIDs: [], provinces: codes, formerProvince: k,
                                                           label: provinceLabels[k] ?? ""))
            }
            for a in Self.provinceAliases {
                let k = PlaceReader.phrase(PlaceReader.words(a.name), PlaceReader.key)
                if let codes = provinceCodes[k] {
                    provinces.add(PlaceReader.words(a.alias), Unit(wardIDs: [], provinces: codes, formerProvince: k, label: provinceLabels[k] ?? ""))
                }
            }
        }
    }

    // MARK: Reading

    private struct Mention { var name: String; var units: [Unit]; var words = 1 }

    /// Words that end an address in a prompt ("45 lê thánh tôn nhé").
    private static let addressEnders: Set<String> = Set(
        ["nhé", "nhe", "nha", "ạ", "nhỉ", "đi", "với", "voi", "và", "va", "thích", "thich", "có", "co", "không", "khong",
         "trong", "within", "bán", "ban", "cách", "cach",
         "ko", "cho", "để", "mà", "ma", "who", "that", "with", "and", "likes"].map(key))
    /// An address is a number or "đường" and at most this many more words.
    private static let addressWords = 6

    /// Words that introduce a street, accented and not.
    private static let streetWords: Set<String> = Set(
        ["đường", "duong", "phố", "pho", "hẻm", "hem", "ngõ", "ngo", "ngách", "ngach", "số", "so"].map(key))

    /// The longest name in `index` starting at `ws[at]`: by exact spelling,
    /// else ignoring accents ("binh thanh", or a half-accented "thu đuc").
    /// Ignoring accents needs two or more words: a single word ("an") could
    /// be any of several names. `single` lifts that when the word is the
    /// whole phrase ("hue").
    private static func longestName(_ ws: [String], at: Int, in index: Gazetteer.Index,
                                    single: Bool = false) -> (count: Int, mention: Mention)? {
        let most = min(index.longest, ws.count - at)
        guard most >= 1 else { return nil }
        for n in stride(from: most, through: 1, by: -1) {
            let part = Array(ws[at..<at + n])
            let k = phrase(part, key)
            if let units = index.exact[k] { return (n, Mention(name: k, units: units)) }
            if n >= 2 || single, let units = index.loose[phrase(part, plain)] {
                return (n, Mention(name: phrase(part, plain), units: units))
            }
        }
        return nil
    }

    /// `strictHome`: a ward named on its own must be in the province the text
    /// names, else in the home one. For a post, where a ward in another
    /// province is far more often a street or venue of the same name
    /// ("Vĩnh Khánh" the food street, not the commune in An Giang).
    static func read(_ text: String, in g: Gazetteer, bare: Bool = false, homeProvince: String? = nil,
                     strictHome: Bool = false) -> Places {
        let ws = words(text)
        let keys = ws.map(key)
        var wardMentions: [Mention] = [], districtMentions: [Mention] = [], provinceMentions: [Mention] = []
        var bareMentions: [Mention] = []
        var out = Places()
        var afterStreet = false     // the previous word was a house number or "đường"
        var address: [String] = [], addressOpen = false
        var i = 0
        while i < ws.count {
            var matched = false
            for k in kinds where i + k.words.count < ws.count && Array(keys[i..<i + k.words.count]) == k.words {
                let at = i + k.words.count
                let indexes: [(Gazetteer.Index, Kind)]
                switch k.kind {
                case .ward: indexes = [(g.wards, .ward)]
                case .district: indexes = [(g.districts, .district)]
                case .province: indexes = [(g.provinces, .province)]
                case .city: indexes = [(g.provinces, .province), (g.districts, .district)]
                }
                for (index, kind) in indexes {
                    guard let hit = longestName(ws, at: at, in: index) else { continue }
                    switch kind {
                    case .ward: wardMentions.append(hit.mention)
                    case .district: districtMentions.append(hit.mention)
                    default: provinceMentions.append(hit.mention)
                    }
                    i = at + hit.count
                    matched = true
                    break
                }
                if matched { break }
            }
            if matched { afterStreet = false; addressOpen = false; continue }

            let province = longestName(ws, at: i, in: g.provinces, single: bare && ws.count == 1)
            // A bare number is a house number, not "Phường 12".
            let numbered = ws[i].allSatisfy(\.isNumber)
            let district = bare && !numbered ? longestName(ws, at: i, in: g.districts, single: ws.count == 1) : nil
            let ward = bare && !numbered ? longestName(ws, at: i, in: g.wards, single: ws.count == 1) : nil
            let longest = max(province?.count ?? 0, district?.count ?? 0, ward?.count ?? 0)
            guard longest > 0 else {
                let isStreet = streetWords.contains(keys[i])
                let isNumber = ws[i].first?.isNumber ?? false
                if bare, isStreet || (isNumber && i + 1 < ws.count) {
                    out.street = true
                    if address.isEmpty { addressOpen = true }
                }
                if addressOpen {
                    if addressEnders.contains(keys[i]) || address.count > addressWords { addressOpen = false }
                    else { address.append(ws[i]) }
                }
                afterStreet = isStreet || isNumber
                i += 1
                continue
            }
            // "45 Lê Lợi", "đường Quang Trung": a street named like a place.
            if bare, afterStreet {
                out.street = true
                if addressOpen { address += ws[i..<i + longest] }
            } else if let p = province, p.count == longest {
                // A province may stand on its own: "ở Hà Nội", "HCM".
                if bare || !Gazetteer.provincesNeedingKind.contains(phrase(Array(ws[i..<i + longest]), plain)) {
                    provinceMentions.append(p.mention)
                } else {
                    afterStreet = false
                    i += 1
                    continue
                }
            } else {
                let units = (district?.count == longest ? district!.mention.units : [])
                    + (ward?.count == longest ? ward!.mention.units : [])
                bareMentions.append(Mention(name: (district?.count == longest ? district : ward)!.mention.name,
                                            units: units, words: longest))
                addressOpen = false
            }
            afterStreet = false
            i += longest
        }

        if out.street, address.count >= 2 { out.streetText = address.joined(separator: " ") }
        let provinceUnits = provinceMentions.flatMap(\.units)
        out.provinceCodes = Set(provinceUnits.flatMap(\.provinces))
        let formerProvinces = Set(provinceUnits.compactMap(\.formerProvince))

        /// Keeps the candidates in a province the text names: by its former
        /// name first ("Bình Dương" is now part of Hồ Chí Minh), then by
        /// today's; a name that isn't in the named province is dropped
        /// ("trung tâm Hồ Chí Minh" is not Phường Trung Tâm, Lào Cai). A text
        /// that names no province prefers the home one, as a hint only.
        func inNamedProvince(_ units: [Unit]) -> [Unit] {
            let former = units.filter { $0.formerProvince.map(formerProvinces.contains) ?? false }
            if !former.isEmpty { return former }
            if !out.provinceCodes.isEmpty { return units.filter { !$0.provinces.isDisjoint(with: out.provinceCodes) } }
            let home = units.filter { u in homeProvince.map(u.provinces.contains) ?? false }
            return home.isEmpty ? units : home
        }
        func take(_ units: [Unit]) {
            out.wardIDs.formUnion(units.flatMap(\.wardIDs))
            for u in units where !u.label.isEmpty && !out.labels.contains(u.label) { out.labels.append(u.label) }
        }
        func isNamed(_ district: String, in names: Set<String>) -> Bool {
            names.contains(district) || names.contains(phrase(district.split(separator: " ").map(String.init), plain))
        }

        let namedDistricts = Set(districtMentions.map(\.name)
            + bareMentions.filter { $0.units.contains(where: \.isDistrict) }.map(\.name))
        var districtsUsed = Set<String>()
        for m in wardMentions {
            var units = m.units
            let inDistrict = units.filter { u in u.district.map { isNamed($0, in: namedDistricts) } ?? false }
            if !inDistrict.isEmpty {
                units = inNamedProvince(inDistrict)
                guard Set(units.flatMap(\.provinces)).count == 1 else { continue }
                districtsUsed.formUnion(units.compactMap(\.district))
                take(units)
                continue
            }
            units = inNamedProvince(units)
            guard Set(units.flatMap(\.provinces)).count == 1 else { continue }
            // Today's name wins over a former ward of the same name.
            let current = units.filter(\.isCurrent)
            if !current.isEmpty {
                take(current)
            } else if Set(units.compactMap(\.district)).count == 1 {
                take(units)
            }
        }
        // A bare name that is a ward of a district the phrase also names
        // ("Bến Nghé, Q1") is that ward, and the district is not widened.
        var placedBare = Set<Int>()
        for (n, m) in bareMentions.enumerated() {
            let others = Set(districtMentions.map(\.name)
                + bareMentions.enumerated().filter { $0.offset != n && $0.element.units.contains(where: \.isDistrict) }.map(\.element.name))
            let inDistrict = inNamedProvince(m.units.filter { u in
                !u.isDistrict && (u.district.map { isNamed($0, in: others) } ?? false)
            })
            guard !inDistrict.isEmpty, Set(inDistrict.flatMap(\.provinces)).count == 1 else { continue }
            districtsUsed.formUnion(inDistrict.compactMap(\.district))
            take(inDistrict)
            placedBare.insert(n)
        }
        // A district named on its own is every ward formed from it.
        for m in districtMentions {
            let units = inNamedProvince(m.units)
            guard Set(units.compactMap(\.formerProvince)).count == 1 else { continue }
            guard Set(units.compactMap(\.district)).isDisjoint(with: districtsUsed) else { continue }
            take(units)
        }
        // A name on its own: the district if it is one, else the ward. A
        // one-word ward name inside a longer phrase ("Hồ" in "Hồ Tây") is too
        // weak to stand without its province.
        let known = out.provinceCodes.isEmpty ? Set([homeProvince].compactMap { $0 }) : out.provinceCodes
        for (n, m) in bareMentions.enumerated() where !placedBare.contains(n) {
            var units = inNamedProvince(m.units)
            if strictHome || (m.words == 1 && ws.count > 1) {
                units = units.filter { $0.isDistrict || (!known.isEmpty && !$0.provinces.isDisjoint(with: known)) }
            }
            guard !units.isEmpty else { continue }
            let districts = units.filter(\.isDistrict)
            if Set(units.flatMap(\.provinces)).count > 1 {
                guard Set(districts.compactMap(\.formerProvince)).count == 1 else { continue }
                units = districts
            } else if !districts.isEmpty {
                units = districts
            } else {
                let current = units.filter(\.isCurrent)
                if !current.isEmpty { units = current }
            }
            guard Set(units.filter(\.isDistrict).compactMap(\.district)).isDisjoint(with: districtsUsed) else { continue }
            take(units)
        }
        if out.labels.isEmpty {
            for u in provinceUnits where !u.label.isEmpty && !out.labels.contains(u.label) { out.labels.append(u.label) }
        }
        return out
    }

    // MARK: Loading

    private actor Cache {
        private var loaded: Gazetteer?
        func get(on db: any SQLDatabase) async throws -> Gazetteer {
            if let g = loaded { return g }
            let wards = try await db.raw("SELECT id::text AS id, name, full_name, province_code, province_name FROM vn_wards")
                .all(decoding: WardRow.self)
            let former = try await db.raw("""
                SELECT f.ward_id::text AS ward_id, w.province_code, f.former_name, f.former_district, f.former_province
                FROM vn_ward_former_names f JOIN vn_wards w ON w.id = f.ward_id
                """).all(decoding: FormerRow.self)
            let g = Gazetteer(wards: wards, former: former)
            loaded = g
            return g
        }
    }
    private static let cache = Cache()

    /// The gazetteer, read once per process: its tables only change by migration.
    static func gazetteer(on db: any SQLDatabase) async throws -> Gazetteer {
        try await cache.get(on: db)
    }

    static func read(_ text: String, on db: any SQLDatabase) async throws -> Places {
        read(text, in: try await gazetteer(on: db))
    }

    // MARK: A place phrase, with the geocoder behind it

    /// Words that introduce a place in a prompt, accented and not.
    private static let placeWords: Set<String> = Set(
        ["ở", "o", "tại", "tai", "gần", "gan", "quanh", "near", "in", "at", "around"].map(key))
    /// How many words after "ở" may belong to the place.
    static let placePhraseWords = 6

    /// What follows "ở / tại / gần" in a prompt, for when the LLM names no
    /// place: "tìm bạn ở thủ đức thích cà phê" → "thủ đức thích cà phê". The
    /// extra words are harmless to `read(bare:)`, which only keeps names.
    static func placePhrase(in prompt: String) -> String? {
        let ws = words(prompt)
        guard let at = ws.firstIndex(where: { placeWords.contains(key($0)) }), at + 1 < ws.count else { return nil }
        return ws[(at + 1)...].prefix(placePhraseWords).joined(separator: " ")
    }

    /// A ward centre further than this from where the geocoder put a place is
    /// not that place's ward.
    static let nearestWardKm = 10.0

    /// Wards for the phrases a place may be in, best first: for a prompt,
    /// what follows "ở" as typed, then what the LLM marked (it respells:
    /// "thu đuc", "45 Le Stung"). Ward, district and province names are read
    /// here; a phrase that only names a province stays a province.
    ///
    /// A street address, or a phrase with no name of ours in it (a venue,
    /// a landmark: "Landmark 81", "Hồ Tây"), goes to the geocoder with the
    /// province it must be in: the one the phrase names, else `homeProvince`.
    /// "12 Nguyễn Trãi" and "Phan Đình Phùng" exist in many cities, and an
    /// answer outside that province is refused. The geocoder must name a ward
    /// of ours; only for an address may the nearest ward centre stand in.
    ///
    /// `venuesInHome`: whether a venue or landmark with no province in its
    /// phrase may be looked up in the home province. Right for a searcher
    /// ("gần Landmark 81"); for a post only when the post itself names the
    /// province, since people write about places far from home.
    static func resolve(_ phrases: [String], homeProvince: String?, strictHome: Bool = false,
                        venuesInHome: Bool = true, client: HTTPClient,
                        on db: any SQLDatabase, logger: Logger) async throws -> Places {
        let g = try await gazetteer(on: db)
        var province: Places?, address: (text: String, local: Places)?, unknown: [String] = []
        for p in phrases {
            let local = read(p, in: g, bare: true, homeProvince: homeProvince, strictHome: strictHome)
            if !local.street, !local.wardIDs.isEmpty { return local }
            if local.street { if address == nil, let text = local.streetText { address = (text, local) } }
            else if !local.provinceCodes.isEmpty { province = province ?? local }
            else { unknown.append(p) }
        }
        let local = address?.local ?? province ?? Places()
        let expected = local.provinceCodes.count == 1 ? local.provinceCodes.first : homeProvince
        let suffix = expected.flatMap { g.provinceNameByCode[$0] }.map { ", " + $0 } ?? ""
        var queries: [String] = []
        if let a = address {
            queries.append(a.text + suffix)
            // The last word may still be chatter the list above doesn't know.
            let ws = a.text.split(separator: " ")
            if ws.count >= 4 { queries.append(ws.dropLast().joined(separator: " ") + suffix) }
        } else if province == nil, venuesInHome {
            queries = unknown.map { $0 + suffix }
        }
        struct Row: Decodable { let id: String; let province_code: String; let full_name: String }
        for query in queries {
            guard let hit = await VenueLocationService.resolveVenueToCity(query, client: client, on: db, logger: logger),
                  let lat = hit.lat, let lng = hit.lng else { continue }
            let named = hit.wardName.map { g.wards.exact[phrase(bareName($0), key)] ?? [] } ?? []
            let ids = named.filter(\.isCurrent).flatMap(\.wardIDs)
            if ids.isEmpty, address == nil { continue }
            var q: SQLQueryString = "SELECT id::text AS id, province_code, full_name FROM vn_wards w WHERE "
            q = q + SearchStore.kmToWard(lat: lat, lng: lng) + " <= \(bind: nearestWardKm)"
            if !ids.isEmpty { q = q + " AND w.id = ANY(\(bind: ids)::uuid[])" }
            if let expected { q = q + " AND w.province_code = \(bind: expected)" }
            q = q + " ORDER BY " + SearchStore.kmToWard(lat: lat, lng: lng) + " LIMIT 1"
            guard let ward = try await db.raw(q).first(decoding: Row.self) else { continue }
            return Places(wardIDs: [ward.id.lowercased()], provinceCodes: local.provinceCodes.union([ward.province_code]),
                          labels: [ward.full_name])
        }
        return local
    }
}
