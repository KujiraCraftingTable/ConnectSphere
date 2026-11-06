import Vapor
import SQLKit
import AsyncHTTPClient
import NIOConcurrencyHelpers

/// Port of `backend/src/services/venueLocationService.js`. Resolve a venue /
/// place name to `{ provinceName, lat, lng }`:
///   bounded in-memory cache → community-validated `location_aliases` → Nominatim.
/// `recordClarification` writes a user-submitted alias (auto-validated when the
/// canonical name itself geocodes).
///
/// LOW review fix: the process-lifetime `geocodeCache` is now a bounded LRU
/// (`cap = 500`) instead of an unbounded Map.
enum VenueLocationService {
    struct Location: Codable, Sendable { var provinceName: String?; var lat: Double?; var lng: Double? }

    static let isoCodeMap: [String: (name: String, lat: Double, lng: Double)] = [
        "VN-HN": ("Hà Nội", 21.0285, 105.8542), "VN-HP": ("Hải Phòng", 20.8449, 106.6881),
        "VN-DN": ("Đà Nẵng", 16.0544, 108.2022), "VN-SG": ("Hồ Chí Minh", 10.7769, 106.7009),
        "VN-CT": ("Cần Thơ", 10.0452, 105.7469), "VN-26": ("Huế", 16.4637, 107.5909),
        "VN-22": ("Nghệ An", 18.6736, 105.6920), "VN-39": ("Đồng Nai", 10.9577, 106.8426),
        "VN-34": ("Khánh Hoà", 12.2388, 109.1968), "VN-07": ("Lào Cai", 22.4856, 103.9754),
        "VN-14": ("Sơn La", 21.3274, 103.9144), "VN-13": ("Lai Châu", 22.3964, 103.4581),
        "VN-11": ("Điện Biên", 21.3861, 103.0230), "VN-09": ("Thái Nguyên", 21.5928, 105.8482),
        "VN-20": ("Lạng Sơn", 21.8537, 106.7614), "VN-03": ("Quảng Ninh", 21.0064, 107.2925),
        "VN-27": ("Bắc Ninh", 21.1861, 106.0763), "VN-25": ("Hưng Yên", 20.6464, 106.0511),
        "VN-37": ("Ninh Bình", 20.2506, 105.9745), "VN-38": ("Thanh Hoá", 19.8071, 105.7852),
        "VN-42": ("Hà Tĩnh", 18.3559, 105.8877), "VN-44": ("Quảng Trị", 16.7943, 107.0014),
        "VN-51": ("Quảng Ngãi", 15.1215, 108.8044), "VN-52": ("Gia Lai", 13.9833, 108.0000),
        "VN-66": ("Đắk Lắk", 12.6667, 108.0500), "VN-68": ("Lâm Đồng", 11.9465, 108.4419),
        "VN-72": ("Tây Ninh", 11.3096, 106.0989), "VN-73": ("Đồng Tháp", 10.4938, 105.6882),
        "VN-86": ("Vĩnh Long", 10.2397, 105.9572), "VN-89": ("An Giang", 10.3833, 105.4333),
        "VN-93": ("Cà Mau", 9.1769, 105.1500), "VN-24": ("Phú Thọ", 21.3465, 105.2352),
        "VN-04": ("Cao Bằng", 22.6655, 106.2522), "VN-08": ("Tuyên Quang", 21.7767, 105.2280),
    ]

    // MARK: bounded LRU cache

    private final class Cache: @unchecked Sendable {
        private let lock = NIOLock()
        private var store: [String: Location?] = [:]
        private var order: [String] = []
        let cap = 500
        func get(_ k: String) -> Location?? { lock.withLock { store[k] } }
        func set(_ k: String, _ v: Location?) {
            lock.withLock {
                if store[k] == nil { order.append(k) }
                store[k] = v
                while order.count > cap { let evict = order.removeFirst(); store[evict] = nil }
            }
        }
    }
    private static let cache = Cache()
    private static func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    // MARK: alias table

    static func toEnglishProvince(_ name: String, on db: any SQLDatabase) async -> String {
        struct R: Decodable { let province_name_en: String? }
        let hit = try? await db.raw("""
            SELECT province_name_en FROM vn_wards
            WHERE province_name ILIKE '%' || \(bind: name) || '%' OR province_name_en ILIKE '%' || \(bind: name) || '%'
            LIMIT 1
            """).first(decoding: R.self)?.province_name_en
        return (hit ?? nil) ?? name
    }

    static func findValidatedAlias(_ placeName: String, on db: any SQLDatabase) async -> Location? {
        guard !placeName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        struct R: Decodable { let canonical: String?; let province_name: String?; let lat: Double?; let lng: Double? }
        guard let hit = try? await db.raw("""
            SELECT canonical, province_name, lat, lng FROM location_aliases
            WHERE alias = \(bind: key(placeName)) AND status = 'validated' LIMIT 1
            """).first(decoding: R.self), let prov = hit.province_name else { return nil }
        return Location(provinceName: prov, lat: hit.lat, lng: hit.lng)
    }

    // MARK: Nominatim

    private static func nominatim(_ placeName: String, limit: Int, client: HTTPClient, logger: Logger) async -> [[String: Any]] {
        let q = placeName.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? placeName
        var req = HTTPClientRequest(url: "https://nominatim.openstreetmap.org/search?q=\(q)&format=json&limit=\(limit)&countrycodes=vn&addressdetails=1")
        req.headers.add(name: "user-agent", value: "ConnectSphere/1.0 (social-networking-app)")
        guard let res = try? await client.execute(req, timeout: .seconds(2500 / 1000 + 1)),
              (200..<300).contains(Int(res.status.code)),
              let buf = try? await res.body.collect(upTo: 512 * 1024),
              let arr = try? JSONSerialization.jsonObject(with: buf) as? [[String: Any]] else {
            logger.warning("Nominatim lookup failed for '\(placeName)'")
            return []
        }
        return arr
    }

    private static func hitToLocation(_ hit: [String: Any], on db: any SQLDatabase) async -> Location? {
        let addr = hit["address"] as? [String: Any] ?? [:]
        guard let latS = hit["lat"] as? String, let lat = Double(latS),
              let lngS = hit["lon"] as? String, let lng = Double(lngS) else { return nil }
        if let iso = addr["ISO3166-2-lvl4"] as? String, let mapped = isoCodeMap[iso] {
            return Location(provinceName: await toEnglishProvince(mapped.name, on: db), lat: lat, lng: lng)
        }
        let rawCity = ((addr["city"] as? String) ?? (addr["state"] as? String) ?? (addr["county"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !rawCity.isEmpty else { return nil }
        let normalized = rawCity.replacingOccurrences(
            of: #"^(tỉnh|thành phố)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return Location(provinceName: await toEnglishProvince(normalized, on: db), lat: lat, lng: lng)
    }

    private static func resolveUncached(_ placeName: String, client: HTTPClient, on db: any SQLDatabase, logger: Logger) async -> Location? {
        guard let hit = await nominatim(placeName, limit: 1, client: client, logger: logger).first else { return nil }
        return await hitToLocation(hit, on: db)
    }

    // MARK: public

    static func resolveVenueToCity(_ placeName: String, client: HTTPClient, on db: any SQLDatabase, logger: Logger) async -> Location? {
        guard !placeName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let k = key(placeName)
        if let cached = cache.get(k) { return cached }
        if let aliased = await findValidatedAlias(placeName, on: db) {
            cache.set(k, aliased); return aliased
        }
        let result = await resolveUncached(placeName, client: client, on: db, logger: logger)
        cache.set(k, result)
        return result
    }

    struct ClarifyResult: Content { var resolved: Bool; @NullCoded var province_name: String?; @NullCoded var lat: Double?; @NullCoded var lng: Double? }

    static func recordClarification(alias: String, canonical: String, userID: String?,
                                    client: HTTPClient, on db: any SQLDatabase, logger: Logger) async throws -> ClarifyResult {
        let k = key(alias)
        let geocoded = await resolveUncached(canonical, client: client, on: db, logger: logger)
        let status = geocoded != nil ? "validated" : "pending"
        try await db.raw("""
            INSERT INTO location_aliases (alias, canonical, province_name, lat, lng, status, submitted_by, reviewed_at)
            VALUES (\(bind: k), \(bind: canonical.trimmingCharacters(in: .whitespaces)), \(bind: geocoded?.provinceName),
                    \(bind: geocoded?.lat), \(bind: geocoded?.lng), \(bind: status), \(uuid: userID),
                    \(unsafeRaw: geocoded != nil ? "NOW()" : "NULL"))
            ON CONFLICT (alias) DO UPDATE SET
              submit_count = location_aliases.submit_count + 1,
              canonical     = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.canonical     ELSE location_aliases.canonical     END,
              province_name = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.province_name ELSE location_aliases.province_name END,
              lat           = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.lat           ELSE location_aliases.lat           END,
              lng           = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.lng           ELSE location_aliases.lng           END,
              status        = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.status        ELSE location_aliases.status        END,
              reviewed_at   = CASE WHEN location_aliases.status = 'pending' AND EXCLUDED.status = 'validated' THEN NOW() ELSE location_aliases.reviewed_at END
            """).run()
        if let g = geocoded { cache.set(k, g) }
        return ClarifyResult(resolved: geocoded != nil, province_name: geocoded?.provinceName,
                             lat: geocoded?.lat, lng: geocoded?.lng)
    }
}
