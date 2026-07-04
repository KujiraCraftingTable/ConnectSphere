const logger = require('../utils/logger');

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

/**
 * Resolve venue/place name to { provinceName, lat, lng } via Nominatim.
 * Returns null if geocoding fails.
 */
async function resolveVenueToCity(placeName) {
  if (!placeName?.trim()) return null;

  try {
    const params = new URLSearchParams({
      q:              placeName.trim(),
      format:         'json',
      limit:          '1',
      countrycodes:   'vn',
      addressdetails: '1',
    });

    const response = await fetch(
      `https://nominatim.openstreetmap.org/search?${params}`,
      {
        headers: { 'User-Agent': 'ConnectSphere/1.0 (social-networking-app)' },
        signal:  AbortSignal.timeout(5_000),
      }
    );

    if (!response.ok) {
      logger.warn({ status: response.status }, 'Nominatim non-OK response');
      return null;
    }

    const data = await response.json();
    if (!Array.isArray(data) || data.length === 0) return null;

    const hit  = data[0];
    const addr = hit.address ?? {};
    const lat  = parseFloat(hit.lat);
    const lng  = parseFloat(hit.lon);

    // 1. Try ISO3166-2-lvl4 first — most reliable after province merger
    const isoCode = addr['ISO3166-2-lvl4'];
    if (isoCode && ISO_CODE_MAP.has(isoCode)) {
      const mapped = ISO_CODE_MAP.get(isoCode);
      logger.debug({ placeName, isoCode, province: mapped.name }, 'Venue geocoded via ISO code');
      return { provinceName: mapped.name, lat, lng };
    }

    // 2. Fallback: derive province name from address fields
    const rawCity = (addr.city || addr.state || addr.county || '').trim();
    if (!rawCity) return null;

    const provinceName = normalizeProvinceName(rawCity);
    logger.debug({ placeName, rawCity, provinceName }, 'Venue geocoded via address text');
    return { provinceName, lat, lng };

  } catch (err) {
    logger.warn({ err, placeName }, 'Venue geocoding failed');
    return null;
  }
}

/**
 * Strip "Tỉnh"/"Thành phố"/"Thành Phố" prefix from raw address city/state string.
 */
function normalizeProvinceName(rawCity) {
  return rawCity.replace(/^(tỉnh|thành phố|thành phố)\s+/i, '').trim();
}

module.exports = { resolveVenueToCity };
