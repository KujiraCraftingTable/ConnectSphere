const logger = require('../utils/logger');
const { query } = require('../config/db');

/**
 * Translate a Vietnamese province name (from the geocoder) to the standard English
 * name used by vn_wards, to match users.location (the app stores English). Falls
 * back to the input if no match is found.
 */
async function toEnglishProvince(name) {
  try {
    const { rows } = await query(
      `SELECT province_name_en FROM vn_wards
       WHERE province_name ILIKE '%' || $1 || '%' OR province_name_en ILIKE '%' || $1 || '%'
       LIMIT 1`,
      [name]
    );
    return rows[0]?.province_name_en ?? name;
  } catch (err) {
    logger.warn({ err, name }, 'toEnglishProvince lookup failed');
    return name;
  }
}

/**
 * ISO 3166-2 province codes → app-standard province name + coordinates.
 * Based on Vietnam's new 34-province structure (2025 merger).
 */
const ISO_CODE_MAP = new Map([
  ['VN-HN', { name: 'Hà Nội',          lat: 21.0285, lng: 105.8542 }],
  ['VN-HP', { name: 'Hải Phòng',        lat: 20.8449, lng: 106.6881 }],
  ['VN-DN', { name: 'Đà Nẵng',          lat: 16.0544, lng: 108.2022 }],
  ['VN-SG', { name: 'Hồ Chí Minh',      lat: 10.7769, lng: 106.7009 }],
  ['VN-CT', { name: 'Cần Thơ',          lat: 10.0452, lng: 105.7469 }],
  ['VN-26', { name: 'Huế',              lat: 16.4637, lng: 107.5909 }],
  ['VN-22', { name: 'Nghệ An',          lat: 18.6736, lng: 105.6920 }],
  ['VN-39', { name: 'Đồng Nai',         lat: 10.9577, lng: 106.8426 }],
  ['VN-34', { name: 'Khánh Hoà',        lat: 12.2388, lng: 109.1968 }],
  ['VN-07', { name: 'Lào Cai',          lat: 22.4856, lng: 103.9754 }],
  ['VN-14', { name: 'Sơn La',           lat: 21.3274, lng: 103.9144 }],
  ['VN-13', { name: 'Lai Châu',         lat: 22.3964, lng: 103.4581 }],
  ['VN-11', { name: 'Điện Biên',        lat: 21.3861, lng: 103.0230 }],
  ['VN-09', { name: 'Thái Nguyên',      lat: 21.5928, lng: 105.8482 }],
  ['VN-20', { name: 'Lạng Sơn',         lat: 21.8537, lng: 106.7614 }],
  ['VN-03', { name: 'Quảng Ninh',       lat: 21.0064, lng: 107.2925 }],
  ['VN-27', { name: 'Bắc Ninh',         lat: 21.1861, lng: 106.0763 }],
  ['VN-25', { name: 'Hưng Yên',         lat: 20.6464, lng: 106.0511 }],
  ['VN-37', { name: 'Ninh Bình',        lat: 20.2506, lng: 105.9745 }],
  ['VN-38', { name: 'Thanh Hoá',        lat: 19.8071, lng: 105.7852 }],
  ['VN-42', { name: 'Hà Tĩnh',          lat: 18.3559, lng: 105.8877 }],
  ['VN-44', { name: 'Quảng Trị',        lat: 16.7943, lng: 107.0014 }],
  ['VN-51', { name: 'Quảng Ngãi',       lat: 15.1215, lng: 108.8044 }],
  ['VN-52', { name: 'Gia Lai',          lat: 13.9833, lng: 108.0000 }],
  ['VN-66', { name: 'Đắk Lắk',          lat: 12.6667, lng: 108.0500 }],
  ['VN-68', { name: 'Lâm Đồng',         lat: 11.9465, lng: 108.4419 }],
  ['VN-72', { name: 'Tây Ninh',         lat: 11.3096, lng: 106.0989 }],
  ['VN-73', { name: 'Đồng Tháp',        lat: 10.4938, lng: 105.6882 }],
  ['VN-86', { name: 'Vĩnh Long',        lat: 10.2397, lng: 105.9572 }],
  ['VN-89', { name: 'An Giang',          lat: 10.3833, lng: 105.4333 }],
  ['VN-93', { name: 'Cà Mau',           lat:  9.1769, lng: 105.1500 }],
  ['VN-24', { name: 'Phú Thọ',          lat: 21.3465, lng: 105.2352 }],
  ['VN-04', { name: 'Cao Bằng',         lat: 22.6655, lng: 106.2522 }],
  ['VN-08', { name: 'Tuyên Quang',       lat: 21.7767, lng: 105.2280 }],
]);

// In-memory cache, unbounded for the process's lifetime — the input space is
// a small, bounded set of Vietnamese cities/venues, so this never grows large,
// and it saves a live Nominatim round trip (network latency, its own rate
// limiting) for every repeat search of a popular place. Caches misses too
// (null), so a place that fails to geocode doesn't keep paying the timeout
// on every subsequent identical search.
const geocodeCache = new Map();

/** Normalized lookup key for an alias — one definition, used by every path. */
const aliasKey = (s) => s.trim().toLowerCase();

/**
 * A location the community has taught the app ("landmark hcmc" → "Landmark 81").
 * Only 'validated' rows are ever readable here: a bad alias steers the hard
 * location filter, so an unreviewed claim must never reach search.
 */
async function findValidatedAlias(placeName) {
  if (!placeName?.trim()) return null;
  try {
    const { rows } = await query(
      `SELECT canonical, province_name, lat, lng
         FROM location_aliases
        WHERE alias = $1 AND status = 'validated'
        LIMIT 1`,
      [aliasKey(placeName)]
    );
    const hit = rows[0];
    if (!hit?.province_name) return null;
    return { provinceName: hit.province_name, lat: hit.lat, lng: hit.lng };
  } catch (err) {
    logger.warn({ err, placeName }, 'findValidatedAlias lookup failed');
    return null;
  }
}

/**
 * Resolve venue/place name to { provinceName, lat, lng }.
 * Order: in-memory cache → community-validated alias → Nominatim.
 * Returns null when nothing can place it. Cached — see geocodeCache above.
 */
async function resolveVenueToCity(placeName) {
  if (!placeName?.trim()) return null;
  const cacheKey = aliasKey(placeName);
  if (geocodeCache.has(cacheKey)) return geocodeCache.get(cacheKey);

  // Tier 1 — something a user already clarified and the geocoder confirmed.
  const aliased = await findValidatedAlias(placeName);
  if (aliased) {
    logger.debug({ placeName, province: aliased.provinceName }, 'Venue resolved via validated alias');
    geocodeCache.set(cacheKey, aliased);
    return aliased;
  }

  const result = await resolveVenueToCityUncached(placeName);
  geocodeCache.set(cacheKey, result);
  return result;
}

/**
 * Record "alias means canonical", submitted by a user from the search warning box.
 *
 * The user supplies a NAME, never coordinates — we geocode `canonical` ourselves,
 * so the worst a bad actor can do is point an alias at some other real place, not
 * inject arbitrary coords. A successful geocode is objective proof the clarification
 * is real, so it auto-validates; otherwise it waits for the CLI data controller.
 *
 * Returns { resolved, provinceName, lat, lng } so the caller can immediately re-run
 * the search with the now-known location.
 */
async function recordClarification({ alias, canonical, userId }) {
  const key = aliasKey(alias);
  const geocoded = await resolveVenueToCityUncached(canonical);
  const status = geocoded ? 'validated' : 'pending';

  try {
    await query(
      `INSERT INTO location_aliases
         (alias, canonical, province_name, lat, lng, status, submitted_by, reviewed_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (alias) DO UPDATE
         SET submit_count = location_aliases.submit_count + 1,
             -- Only a still-pending row may be upgraded by a later submission;
             -- an already validated or rejected decision is never overwritten.
             canonical     = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.canonical     ELSE location_aliases.canonical     END,
             province_name = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.province_name ELSE location_aliases.province_name END,
             lat           = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.lat           ELSE location_aliases.lat           END,
             lng           = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.lng           ELSE location_aliases.lng           END,
             status        = CASE WHEN location_aliases.status = 'pending' THEN EXCLUDED.status        ELSE location_aliases.status        END,
             reviewed_at   = CASE WHEN location_aliases.status = 'pending' AND EXCLUDED.status = 'validated' THEN NOW() ELSE location_aliases.reviewed_at END`,
      [key, canonical.trim(), geocoded?.provinceName ?? null, geocoded?.lat ?? null, geocoded?.lng ?? null,
       status, userId ?? null, geocoded ? new Date() : null]
    );
  } catch (err) {
    logger.warn({ err, alias: key }, 'recordClarification write failed');
    // The write failing shouldn't deny the user their re-run — they still get
    // the geocode result, the app just doesn't learn from it this time.
  }

  // A newly validated alias must not be shadowed by the cached miss that
  // produced the warning in the first place.
  if (geocoded) geocodeCache.set(key, geocoded);

  logger.info({ alias: key, canonical, status }, 'Location clarification recorded');
  return {
    resolved:     !!geocoded,
    provinceName: geocoded?.provinceName ?? null,
    lat:          geocoded?.lat ?? null,
    lng:          geocoded?.lng ?? null,
  };
}

/**
 * Turn one raw Nominatim search result into { provinceName, lat, lng }, or null
 * if it doesn't resolve to a province at all. Shared by the single-best-guess
 * path (resolveVenueToCityUncached) and the multi-candidate path
 * (searchVenueCandidates) so the ISO-code/address-fallback logic lives once.
 */
async function hitToLocation(hit, placeName) {
  const addr = hit.address ?? {};
  const lat  = parseFloat(hit.lat);
  const lng  = parseFloat(hit.lon);

  // 1. Try ISO3166-2-lvl4 first — most reliable after province merger
  const isoCode = addr['ISO3166-2-lvl4'];
  if (isoCode && ISO_CODE_MAP.has(isoCode)) {
    const mapped = ISO_CODE_MAP.get(isoCode);
    const provinceName = await toEnglishProvince(mapped.name); // VN → EN to match users.location
    logger.debug({ placeName, isoCode, province: provinceName }, 'Venue geocoded via ISO code');
    return { provinceName, lat, lng };
  }

  // 2. Fallback: derive province name from address fields
  const rawCity = (addr.city || addr.state || addr.county || '').trim();
  if (!rawCity) return null;

  const provinceName = await toEnglishProvince(normalizeProvinceName(rawCity));
  logger.debug({ placeName, rawCity, provinceName }, 'Venue geocoded via address text');
  return { provinceName, lat, lng };
}

async function nominatimSearch(placeName, limit) {
  const params = new URLSearchParams({
    q:              placeName.trim(),
    format:         'json',
    limit:          String(limit),
    countrycodes:   'vn',
    addressdetails: '1',
  });

  const response = await fetch(
    `https://nominatim.openstreetmap.org/search?${params}`,
    {
      headers: { 'User-Agent': 'ConnectSphere/1.0 (social-networking-app)' },
      signal:  AbortSignal.timeout(2_500),
    }
  );

  if (!response.ok) {
    logger.warn({ status: response.status }, 'Nominatim non-OK response');
    return [];
  }

  const data = await response.json();
  return Array.isArray(data) ? data : [];
}

async function resolveVenueToCityUncached(placeName) {
  try {
    const [hit] = await nominatimSearch(placeName, 1);
    if (!hit) return null;
    return await hitToLocation(hit, placeName);
  } catch (err) {
    logger.warn({ err, placeName }, 'Venue geocoding failed');
    return null;
  }
}

/**
 * Like resolveVenueToCityUncached, but returns up to `limit` candidates instead
 * of committing to Nominatim's single best guess — for the CLI reviewer to show
 * "did you mean one of these?" when the exact canonical text didn't resolve.
 * Fail-soft like every other lookup here: [] on any error, never throws.
 */
async function searchVenueCandidates(text, limit = 5) {
  if (!text?.trim()) return [];
  try {
    const hits = await nominatimSearch(text, limit);
    const candidates = [];
    for (const hit of hits) {
      const located = await hitToLocation(hit, text);
      if (located) candidates.push({ label: hit.display_name, ...located });
      if (candidates.length >= limit) break;
    }
    return candidates;
  } catch (err) {
    logger.warn({ err, text }, 'searchVenueCandidates failed');
    return [];
  }
}

/**
 * Strip "Tỉnh"/"Thành phố"/"Thành Phố" prefix from raw address city/state string.
 */
function normalizeProvinceName(rawCity) {
  return rawCity.replace(/^(tỉnh|thành phố|thành phố)\s+/i, '').trim();
}

module.exports = { resolveVenueToCity, findValidatedAlias, recordClarification, searchVenueCandidates };
