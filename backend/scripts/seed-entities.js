/**
 * seed-entities.js
 *
 * Seeds ~1 000 canonical interest entities from Wikidata into the
 * interest_entities table.
 *
 * Usage:
 *   node scripts/seed-entities.js            # insert only
 *   node scripts/seed-entities.js --embed    # insert + generate embeddings via Ollama
 *
 * Options:
 *   --embed    Generate mxbai-embed-large embeddings after seeding (requires
 *              Ollama running with mxbai-embed-large pulled)
 *   --dry-run  Print what would be inserted without touching the DB
 */

require('dotenv').config();
const { Pool }  = require('pg');
const https     = require('https');
const http      = require('http');
const env       = require('../src/config/env');

const EMBED    = process.argv.includes('--embed');
const DRY_RUN  = process.argv.includes('--dry-run');
const OLLAMA   = 'http://localhost:11434';

// ─── Wikidata helpers ─────────────────────────────────────────────────────────

const WIKIDATA_SPARQL = 'https://query.wikidata.org/sparql';

/** Execute a SPARQL query and return parsed bindings. */
async function sparql(query) {
  const url = `${WIKIDATA_SPARQL}?query=${encodeURIComponent(query)}&format=json`;
  return new Promise((resolve, reject) => {
    const req = https.get(url, {
      headers: { 'User-Agent': 'ConnectSphere/1.0 (educational; contact@connectsphere.local)' },
      timeout: 30_000,
    }, (res) => {
      let raw = '';
      res.on('data', (d) => (raw += d));
      res.on('end', () => {
        try { resolve(JSON.parse(raw).results.bindings); }
        catch (e) { reject(new Error(`SPARQL parse error: ${e.message}\n${raw.slice(0, 400)}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('SPARQL timeout')); });
  });
}

/** Sleep ms */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── SPARQL queries per category ─────────────────────────────────────────────

const QUERIES = {

  Anime: `
    SELECT DISTINCT ?item ?itemLabel ?itemAltLabel WHERE {
      {
        ?item wdt:P31 wd:Q63952888.     # anime television series
      } UNION {
        ?item wdt:P31 wd:Q20650540.     # anime film
      } UNION {
        ?item wdt:P31 wd:Q1107;         # anime (general)
              wdt:P136 wd:Q1107.        # genre: anime
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,ja". }
    }
    ORDER BY DESC(?item)
    LIMIT 300
  `,

  Movies: `
    SELECT DISTINCT ?item ?itemLabel ?itemAltLabel WHERE {
      ?item wdt:P31 wd:Q11424;          # instance of: film
            wdt:P166 [];                # has received award (notable films)
            wdt:P577 ?date.
      FILTER(YEAR(?date) >= 2000)
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    ORDER BY DESC(?date)
    LIMIT 300
  `,

  Gaming: `
    SELECT DISTINCT ?item ?itemLabel ?itemAltLabel WHERE {
      ?item wdt:P31 wd:Q7889;           # instance of: video game
            wdt:P136 [];                # has genre
            wdt:P18 [].                 # has image
      FILTER NOT EXISTS { ?item wdt:P31 wd:Q693346 }  # not DLC
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    ORDER BY DESC(?item)
    LIMIT 250
  `,

  Music: `
    SELECT DISTINCT ?item ?itemLabel ?itemAltLabel WHERE {
      { ?item wdt:P31 wd:Q5741069. }   # rock band
      UNION
      { ?item wdt:P31 wd:Q215380. }    # musical group
      UNION
      { ?item wdt:P31 wd:Q177220; wdt:P136 []. }  # singer with genre
      ?item wdt:P18 [].
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    ORDER BY DESC(?item)
    LIMIT 200
  `,

  Books: `
    SELECT DISTINCT ?item ?itemLabel ?itemAltLabel WHERE {
      ?item wdt:P31 wd:Q571;            # instance of: book
            wdt:P166 [];                # has received award
            wdt:P577 ?date.
      FILTER(YEAR(?date) >= 1990)
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    ORDER BY DESC(?date)
    LIMIT 150
  `,
};

// ─── Parse Wikidata bindings → entity rows ────────────────────────────────────

/**
 * Convert SPARQL bindings into { canonical_name, category, aliases, wikidata_id }
 * Filters out auto-generated Q-number labels (means Wikidata has no English label).
 */
function parseBindings(bindings, category) {
  const entities = [];
  for (const b of bindings) {
    const label = b.itemLabel?.value ?? '';
    const qid   = b.item?.value?.split('/').pop() ?? '';        // "Q12345"
    const altRaw = b.itemAltLabel?.value ?? '';

    // Skip items with no real English label (they show as "Q12345")
    if (!label || /^Q\d+$/.test(label)) continue;

    const aliases = altRaw
      ? [...new Set(altRaw.split(',').map((s) => s.trim()).filter(Boolean))]
      : [];

    entities.push({ canonical_name: label, category, aliases, wikidata_id: qid });
  }
  return entities;
}

// ─── DB upsert ────────────────────────────────────────────────────────────────

async function upsertEntities(pool, entities) {
  let inserted = 0, skipped = 0;
  for (const e of entities) {
    try {
      const res = await pool.query(
        `INSERT INTO interest_entities (canonical_name, category, aliases, wikidata_id)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (canonical_name, category) DO NOTHING
         RETURNING id`,
        [e.canonical_name, e.category, e.aliases, e.wikidata_id || null]
      );
      if (res.rowCount > 0) inserted++;
      else skipped++;
    } catch (err) {
      console.warn(`  ⚠  skip "${e.canonical_name}": ${err.message}`);
      skipped++;
    }
  }
  return { inserted, skipped };
}

// ─── Ollama embeddings ────────────────────────────────────────────────────────

/** Generate a single 768-dim embedding via Ollama mxbai-embed-large */
async function embedText(text) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ model: 'mxbai-embed-large', prompt: text });
    const req  = http.request(`${OLLAMA}/api/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 30_000,
    }, (res) => {
      let raw = '';
      res.on('data', (d) => (raw += d));
      res.on('end', () => {
        try { resolve(JSON.parse(raw).embedding); }
        catch (e) { reject(new Error(`Embed parse: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Embed timeout')); });
    req.write(body);
    req.end();
  });
}

/** Embed all entities that are missing an embedding vector (batch, with progress). */
async function embedAllEntities(pool) {
  const { rows } = await pool.query(
    'SELECT id, canonical_name, category FROM interest_entities WHERE embedding IS NULL ORDER BY category, canonical_name'
  );
  console.log(`\n🔢 Embedding ${rows.length} entities with mxbai-embed-large…`);

  let done = 0;
  for (const row of rows) {
    // Embed canonical name + category for richer context
    const text = `${row.canonical_name} (${row.category})`;
    try {
      const vec = await embedText(text);
      await pool.query(
        'UPDATE interest_entities SET embedding = $1 WHERE id = $2',
        [`[${vec.join(',')}]`, row.id]
      );
      done++;
      if (done % 50 === 0) {
        console.log(`  … ${done}/${rows.length} embedded`);
      }
    } catch (err) {
      console.warn(`  ⚠  embed failed for "${row.canonical_name}": ${err.message}`);
    }
    // Small delay to avoid hammering Ollama
    await sleep(50);
  }
  console.log(`  ✓ ${done}/${rows.length} entities embedded`);

  // HNSW index — already created by 001_init.sql; this is a safety net in case
  // this script runs against a DB where the baseline index is missing.
  console.log('\n📐 Ensuring HNSW vector index exists…');
  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_entities_embedding
      ON interest_entities
      USING hnsw (embedding vector_cosine_ops)
  `);
  console.log('  ✓ Index ready');
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const pool = new Pool(env.db);

  let totalInserted = 0;
  let totalEntities = [];

  for (const [category, query] of Object.entries(QUERIES)) {
    process.stdout.write(`\n🌐 Fetching ${category} from Wikidata… `);
    let bindings;
    try {
      bindings = await sparql(query);
    } catch (err) {
      console.error(`FAILED: ${err.message}`);
      // Don't abort — try next category
      await sleep(2_000);
      continue;
    }

    const entities = parseBindings(bindings, category);
    console.log(`${entities.length} entities`);

    if (DRY_RUN) {
      entities.slice(0, 5).forEach((e) =>
        console.log(`  ${e.canonical_name} | aliases: [${e.aliases.slice(0, 3).join(', ')}]`)
      );
      totalEntities.push(...entities);
    } else {
      const { inserted, skipped } = await upsertEntities(pool, entities);
      console.log(`  ✓ inserted: ${inserted}  skipped/dup: ${skipped}`);
      totalInserted += inserted;
    }

    // Be polite to Wikidata — 1 s between queries
    await sleep(1_000);
  }

  if (DRY_RUN) {
    console.log(`\n[dry-run] Would insert up to ${totalEntities.length} entities.`);
    await pool.end();
    return;
  }

  console.log(`\n✅ Seed complete — ${totalInserted} new entities inserted`);

  if (EMBED) {
    await embedAllEntities(pool);
  } else {
    console.log('\n💡 Tip: run with --embed to generate vector embeddings');
    console.log('   (requires: ollama pull mxbai-embed-large)');
  }

  await pool.end();
}

main().catch((err) => {
  console.error('Fatal:', err);
  process.exit(1);
});
