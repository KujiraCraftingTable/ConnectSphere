/**
 * generate-wards-sql.js
 *
 * Generates 016_vn_wards.sql using:
 * - Accurate coordinates from wards-geocode-progress.json (Nominatim-geocoded wards)
 * - Province centroid fallback for remaining wards
 *
 * Usage: node scripts/generate-wards-sql.js
 */

const fs   = require('fs');
const path = require('path');

const INPUT    = path.join(__dirname, 'vn_units.json');
const PROGRESS = path.join(__dirname, 'wards-geocode-progress.json');
const OUTPUT   = path.join(__dirname, '../migrations/003_seed_vn_wards.sql');

const PROVINCE_CENTROIDS = {
  '01': [21.0285, 105.8542],
  '04': [22.6655, 106.2522],
  '08': [21.7767, 105.2280],
  '11': [21.3861, 103.0230],
  '12': [22.3964, 103.4581],
  '14': [21.3274, 103.9144],
  '15': [22.4856, 103.9754],
  '19': [21.5928, 105.8482],
  '20': [21.8537, 106.7614],
  '22': [21.0064, 107.2925],
  '24': [21.1861, 106.0763],
  '25': [21.3465, 105.2352],
  '31': [20.8449, 106.6881],
  '33': [20.6464, 106.0511],
  '37': [20.2506, 105.9745],
  '38': [19.8071, 105.7852],
  '40': [18.6736, 105.6920],
  '42': [18.3559, 105.8877],
  '44': [16.7943, 107.0014],
  '46': [16.4637, 107.5909],
  '48': [16.0544, 108.2022],
  '51': [15.1215, 108.8044],
  '52': [13.9833, 108.0000],
  '56': [12.2388, 109.1968],
  '66': [12.6667, 108.0500],
  '68': [11.9465, 108.4419],
  '75': [10.9577, 106.8426],
  '79': [10.7769, 106.7009],
  '80': [11.3096, 106.0989],
  '82': [10.4938, 105.6882],
  '86': [10.2397, 105.9572],
  '91': [10.3833, 105.4333],
  '92': [10.0452, 105.7469],
  '96': [ 9.1769, 105.1500],
};

function esc(s) { return s.replace(/'/g, "''"); }

const units    = JSON.parse(fs.readFileSync(INPUT, 'utf8'));
const progress = fs.existsSync(PROGRESS)
  ? JSON.parse(fs.readFileSync(PROGRESS, 'utf8'))
  : {};

const lines = [
  '-- 016_vn_wards.sql',
  '-- Vietnamese administrative units — 34 new provinces, 3321 wards',
  '-- Coordinates: Nominatim for geocoded wards; province centroid fallback for remainder',
  '',
  'CREATE TABLE IF NOT EXISTS vn_wards (',
  '  id               UUID             PRIMARY KEY DEFAULT gen_random_uuid(),',
  '  code             VARCHAR(10)      NOT NULL UNIQUE,',
  '  name             TEXT             NOT NULL,',
  '  name_en          TEXT             NOT NULL,',
  '  full_name        TEXT             NOT NULL,',
  '  full_name_en     TEXT             NOT NULL,',
  '  province_code    VARCHAR(5)       NOT NULL,',
  '  province_name    TEXT             NOT NULL,',
  '  province_name_en TEXT             NOT NULL,',
  '  unit_type        VARCHAR(30)      NOT NULL,',
  '  lat              DOUBLE PRECISION NOT NULL,',
  '  lng              DOUBLE PRECISION NOT NULL',
  ');',
  '',
  'CREATE INDEX IF NOT EXISTS idx_vn_wards_province ON vn_wards (province_code);',
  'CREATE INDEX IF NOT EXISTS idx_vn_wards_code     ON vn_wards (code);',
  '',
];

let exact = 0, fallback = 0;

for (const province of units) {
  for (const ward of (province.Wards || [])) {
    let lat, lng;
    if (progress[ward.Code]) {
      lat = progress[ward.Code].lat;
      lng = progress[ward.Code].lng;
      if (!progress[ward.Code].fallback) exact++;
      else fallback++;
    } else {
      const c = PROVINCE_CENTROIDS[province.Code] || [16.0, 106.0];
      lat = c[0]; lng = c[1];
      fallback++;
    }

    lines.push(
      `INSERT INTO vn_wards (code,name,name_en,full_name,full_name_en,province_code,province_name,province_name_en,unit_type,lat,lng) VALUES (` +
      `'${esc(ward.Code)}','${esc(ward.Name)}','${esc(ward.NameEn)}',` +
      `'${esc(ward.FullName)}','${esc(ward.FullNameEn)}',` +
      `'${esc(province.Code)}','${esc(province.FullName)}','${esc(province.FullNameEn)}',` +
      `'${esc(ward.AdministrativeUnitShortNameEn)}',` +
      `${lat},${lng}) ON CONFLICT (code) DO NOTHING;`
    );
  }
}

fs.writeFileSync(OUTPUT, lines.join('\n'), 'utf8');
console.log(`✅ Generated ${OUTPUT}`);
console.log(`   Exact coords: ${exact} | Province centroid fallback: ${fallback}`);
