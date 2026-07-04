/**
 * geocode-wards.js
 *
 * Reads vn_units.json (34 new provinces, 3321 wards),
 * geocodes each ward via Nominatim, outputs 016_vn_wards.sql
 *
 * Usage: node scripts/geocode-wards.js
 * Output: migrations/003_seed_vn_wards.sql
 *
 * Rate: 1 req/sec (Nominatim limit). ~60 min total.
 * Failed geocodes fall back to province centroid.
 */

const https = require('https');
const fs    = require('fs');
const path  = require('path');

const INPUT  = path.join(__dirname, 'vn_units.json');
const OUTPUT = path.join(__dirname, '../migrations/003_seed_vn_wards.sql');
const PROGRESS = path.join(__dirname, 'wards-geocode-progress.json');

const DELAY_MS = 1100; // Nominatim rate limit: 1 req/sec
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Province centroids — fallback when ward geocode fails
const PROVINCE_CENTROIDS = {
  '01': [21.0285, 105.8542],  // Hà Nội
  '04': [22.6655, 106.2522],  // Cao Bằng
  '08': [21.7767, 105.2280],  // Tuyên Quang
  '11': [21.3861, 103.0230],  // Điện Biên
  '12': [22.3964, 103.4581],  // Lai Châu
  '14': [21.3274, 103.9144],  // Sơn La
  '15': [22.4856, 103.9754],  // Lào Cai
  '19': [21.5928, 105.8482],  // Thái Nguyên
  '20': [21.8537, 106.7614],  // Lạng Sơn
  '22': [21.0064, 107.2925],  // Quảng Ninh
  '24': [21.1861, 106.0763],  // Bắc Ninh
  '25': [21.3465, 105.2352],  // Phú Thọ
  '31': [20.8449, 106.6881],  // Hải Phòng
  '33': [20.6464, 106.0511],  // Hưng Yên
  '37': [20.2506, 105.9745],  // Ninh Bình
  '38': [19.8071, 105.7852],  // Thanh Hoá
  '40': [18.6736, 105.6920],  // Nghệ An
  '42': [18.3559, 105.8877],  // Hà Tĩnh
  '44': [16.7943, 107.0014],  // Quảng Trị
  '46': [16.4637, 107.5909],  // Huế
  '48': [16.0544, 108.2022],  // Đà Nẵng
  '51': [15.1215, 108.8044],  // Quảng Ngãi
  '52': [13.9833, 108.0000],  // Gia Lai
  '56': [12.2388, 109.1968],  // Khánh Hoà
  '66': [12.6667, 108.0500],  // Đắk Lắk
  '68': [11.9465, 108.4419],  // Lâm Đồng
  '75': [10.9577, 106.8426],  // Đồng Nai
  '79': [10.7769, 106.7009],  // Hồ Chí Minh
  '80': [11.3096, 106.0989],  // Tây Ninh
  '82': [10.4938, 105.6882],  // Đồng Tháp
  '86': [10.2397, 105.9572],  // Vĩnh Long
  '91': [10.3833, 105.4333],  // An Giang
  '92': [10.0452, 105.7469],  // Cần Thơ
  '96': [9.1769,  105.1500],  // Cà Mau
};

// ─── Nominatim ────────────────────────────────────────────────────────────────

function nominatimGet(url) {
  return new Promise((resolve) => {
    const req = https.get(url, {
      headers: { 'User-Agent': 'ConnectSphere/1.0 (educational)' },
      timeout: 8000,
    }, (res) => {
      let raw = '';
      res.on('data', d => raw += d);
      res.on('end', () => {
        try { resolve(JSON.parse(raw)); }
        catch { resolve([]); }
      });
    });
    req.on('error', () => resolve([]));
    req.on('timeout', () => { req.destroy(); resolve([]); });
  });
}

async function geocodeWard(wardFullName, provinceFullName) {
  const q = encodeURIComponent(`${wardFullName}, ${provinceFullName}, Vietnam`);
  const url = `https://nominatim.openstreetmap.org/search?q=${q}&format=json&limit=1&countrycodes=vn`;
  const results = await nominatimGet(url);
  if (results.length > 0) {
    return { lat: parseFloat(results[0].lat), lng: parseFloat(results[0].lon) };
  }
  return null;
}

// ─── SQL helpers ──────────────────────────────────────────────────────────────

function esc(s) { return s.replace(/'/g, "''"); }

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const units = JSON.parse(fs.readFileSync(INPUT, 'utf8'));

  // Load progress if resuming
  let progress = {};
  if (fs.existsSync(PROGRESS)) {
    progress = JSON.parse(fs.readFileSync(PROGRESS, 'utf8'));
    console.log(`Resuming — ${Object.keys(progress).length} wards already geocoded`);
  }

  // Count totals
  let totalWards = 0;
  for (const p of units) totalWards += (p.Wards || []).length;
  console.log(`Total: ${units.length} provinces, ${totalWards} wards\n`);

  let done = 0, failed = 0;

  // Geocode all wards
  for (const province of units) {
    const wards = province.Wards || [];
    for (const ward of wards) {
      const key = ward.Code;
      if (!progress[key]) {
        const coords = await geocodeWard(ward.FullName, province.FullName);
        if (coords) {
          progress[key] = coords;
        } else {
          // Fallback to province centroid
          const c = PROVINCE_CENTROIDS[province.Code] || [16.0, 106.0];
          progress[key] = { lat: c[0], lng: c[1], fallback: true };
          failed++;
        }
        done++;
        if (done % 50 === 0) {
          process.stdout.write(`  … ${done}/${totalWards} (${failed} fallback)\n`);
          // Save progress checkpoint
          fs.writeFileSync(PROGRESS, JSON.stringify(progress));
        }
        await sleep(DELAY_MS);
      } else {
        done++;
      }
    }
  }

  // Save final progress
  fs.writeFileSync(PROGRESS, JSON.stringify(progress));
  console.log(`\nGeocode done: ${done} total, ${failed} used province centroid fallback`);

  // Generate SQL
  console.log('\nGenerating SQL...');
  const lines = [
    '-- 016_vn_wards.sql',
    '-- Vietnamese administrative units (34 new provinces, 3321 wards)',
    '-- Coordinates from Nominatim geocoding; province centroid used as fallback',
    '',
    'CREATE TABLE IF NOT EXISTS vn_wards (',
    '  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),',
    '  code          VARCHAR(10)   NOT NULL UNIQUE,',
    '  name          TEXT          NOT NULL,',
    '  name_en       TEXT          NOT NULL,',
    '  full_name     TEXT          NOT NULL,',
    '  full_name_en  TEXT          NOT NULL,',
    '  province_code VARCHAR(5)    NOT NULL,',
    '  province_name TEXT          NOT NULL,',
    '  province_name_en TEXT       NOT NULL,',
    '  unit_type     VARCHAR(30)   NOT NULL,',
    '  lat           DOUBLE PRECISION NOT NULL,',
    '  lng           DOUBLE PRECISION NOT NULL',
    ');',
    '',
    'CREATE INDEX IF NOT EXISTS idx_vn_wards_province ON vn_wards (province_code);',
    'CREATE INDEX IF NOT EXISTS idx_vn_wards_code ON vn_wards (code);',
    '',
  ];

  for (const province of units) {
    const wards = province.Wards || [];
    for (const ward of wards) {
      const coords = progress[ward.Code] || { lat: 16.0, lng: 106.0 };
      lines.push(
        `INSERT INTO vn_wards (code, name, name_en, full_name, full_name_en, province_code, province_name, province_name_en, unit_type, lat, lng) VALUES (` +
        `'${esc(ward.Code)}', ` +
        `'${esc(ward.Name)}', ` +
        `'${esc(ward.NameEn)}', ` +
        `'${esc(ward.FullName)}', ` +
        `'${esc(ward.FullNameEn)}', ` +
        `'${esc(province.Code)}', ` +
        `'${esc(province.FullName)}', ` +
        `'${esc(province.FullNameEn)}', ` +
        `'${esc(ward.AdministrativeUnitShortNameEn)}', ` +
        `${coords.lat}, ${coords.lng}` +
        `) ON CONFLICT (code) DO NOTHING;`
      );
    }
  }

  fs.writeFileSync(OUTPUT, lines.join('\n'), 'utf8');
  console.log(`\n✅ SQL written to ${OUTPUT}`);
  console.log(`   ${totalWards} INSERT statements`);
}

main().catch(err => { console.error('Fatal:', err); process.exit(1); });
