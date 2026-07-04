/**
 * entityLookupService.js
 *
 * 3-tier lookup: text input → canonical interest_entity
 *
 * Tier 1 — Exact match:      canonical_name or aliases[] (fastest, O(1) index)
 * Tier 2 — Vector search:    embed input → cosine similarity ≥ 0.65, saves alias on match
 * Tier 3 — Wikipedia:        fallback for proper nouns not in DB; fetches EN/JA/VI data,
 *                            LLM-parses into entity record, inserts into interest_entities
 *                            so tier 1 catches it next time
 *
 * Return: { entity_id, canonical_name, category, confidence, genre_tags? }
 *   confidence: 'exact' | 'vector' | 'wikipedia' | 'none'
 *   genre_tags: string[] — only present when confidence === 'wikipedia'
 */

const { query } = require('../config/db');
const { ollama } = require('../config/env');
const logger = require('../utils/logger');
const { isProperNoun, searchWikipedia, parseWikiData } = require('./wikipediaService');
const EMBED_MODEL       = 'mxbai-embed-large';
const VECTOR_THRESHOLD  = 0.65;   // cosine similarity tối thiểu cho tier 2

// ─── Tier 1: Exact match ──────────────────────────────────────────────────────

async function exactMatch(text, category) {
  const normalized = text.trim().toLowerCase();

  const { rows } = await query(
    `SELECT id, canonical_name, category
     FROM interest_entities
     WHERE (
       LOWER(canonical_name) = $1
       OR $1 = ANY(SELECT LOWER(a) FROM UNNEST(aliases) a)
     )
     AND ($2::text IS NULL OR category = $2)
     LIMIT 1`,
    [normalized, category || null]
  );

  return rows[0] || null;
}

// ─── Tier 2: Vector similarity ────────────────────────────────────────────────

async function embedText(text) {
  const response = await fetch(`${ollama.url}/api/embeddings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: EMBED_MODEL, prompt: text }),
    signal: AbortSignal.timeout(15_000),
  });

  if (!response.ok) throw new Error(`Embed error: ${response.status}`);
  const data = await response.json();
  return data.embedding; // number[]
}

async function vectorSearch(text, category) {
  let embedding;
  try {
    embedding = await embedText(text);
  } catch (err) {
    logger.warn({ err }, 'Embed failed — skipping vector tier');
    return null;
  }

  const vecLiteral = `[${embedding.join(',')}]`;

  const { rows } = await query(
    `SELECT id, canonical_name, category,
            1 - (embedding <=> $1::vector) AS similarity
     FROM interest_entities
     WHERE embedding IS NOT NULL
       AND ($2::text IS NULL OR category = $2)
     ORDER BY embedding <=> $1::vector
     LIMIT 1`,
    [vecLiteral, category || null]
  );

  if (!rows[0]) return null;

  const sim = parseFloat(rows[0].similarity);
  logger.debug({ text, match: rows[0].canonical_name, similarity: sim }, 'Vector search result');

  if (sim < VECTOR_THRESHOLD) return null;

  return rows[0];
}

/** Sau khi vector match, tìm entity trong DB và lưu alias để lần sau dùng tier 1 */
async function findAndSaveAlias(text, llmResult) {
  // Tìm entity trong DB theo canonical_name — exact trước, rồi partial (ILIKE)
  let { rows } = await query(
    `SELECT id, canonical_name, category, aliases
     FROM interest_entities
     WHERE LOWER(canonical_name) = LOWER($1)
       AND ($2::text IS NULL OR category = $2)
     LIMIT 1`,
    [llmResult.canonical_name, llmResult.category || null]
  );

  // Fallback: tìm partial match (e.g. "Kimetsu no Yaiba" khớp với "Demon Slayer: Kimetsu no Yaiba...")
  if (!rows[0]) {
    const partial = await query(
      `SELECT id, canonical_name, category, aliases
       FROM interest_entities
       WHERE canonical_name ILIKE $1
         AND ($2::text IS NULL OR category = $2)
       LIMIT 1`,
      [`%${llmResult.canonical_name}%`, llmResult.category || null]
    );
    rows = partial.rows;
  }

  if (!rows[0]) return null;

  const entity = rows[0];
  const alias  = text.trim();

  // Lưu alias nếu chưa có (tránh duplicate)
  if (!entity.aliases.map((a) => a.toLowerCase()).includes(alias.toLowerCase())) {
    await query(
      `UPDATE interest_entities
       SET aliases = array_append(aliases, $1)
       WHERE id = $2`,
      [alias, entity.id]
    );
    logger.info({ alias, canonical: entity.canonical_name }, 'New alias saved');
  }

  return entity;
}

// ─── Main lookup ──────────────────────────────────────────────────────────────

/**
 * Lookup entity cho một interest input.
 *
 * @param {string} text         - Input của user, e.g. "KNY", "demon slayer"
 * @param {string} [category]   - Gợi ý category nếu đã biết, e.g. "Anime"
 * @returns {{ entity_id, canonical_name, category, confidence }}
 */
async function lookupEntity(text, category = null) {
  if (!text?.trim()) {
    return { entity_id: null, canonical_name: null, category: null, confidence: 'none' };
  }

  // Tier 1 — Exact match
  const exact = await exactMatch(text, category);
  if (exact) {
    logger.debug({ text, match: exact.canonical_name }, 'Tier 1 exact match');
    return {
      entity_id:      exact.id,
      canonical_name: exact.canonical_name,
      category:       exact.category,
      confidence:     'exact',
    };
  }

  // Tier 2 — Vector similarity
  const vector = await vectorSearch(text, category);
  if (vector) {
    logger.debug({ text, match: vector.canonical_name }, 'Tier 2 vector match');
    // Save alias fire-and-forget — không block response, lỗi chỉ log warn
    findAndSaveAlias(text, { canonical_name: vector.canonical_name, category: vector.category })
      .catch((err) => logger.warn({ err, text }, 'findAndSaveAlias failed after vector match'));
    return {
      entity_id:      vector.id,
      canonical_name: vector.canonical_name,
      category:       vector.category,
      confidence:     'vector',
    };
  }

  // Tier 3 — Wikipedia fallback (proper nouns only)
  if (isProperNoun(text)) {
    try {
      const wikiData = await searchWikipedia(text);
      if (wikiData) {
        const parsed = await parseWikiData(wikiData);
        if (parsed) {
          // Insert into interest_entities; merge aliases if entity already exists
          const { rows } = await query(
            `INSERT INTO interest_entities (canonical_name, aliases, category)
             VALUES ($1, $2, $3)
             ON CONFLICT (canonical_name, category) DO UPDATE
               SET aliases = (
                 SELECT array_agg(DISTINCT a ORDER BY a)
                 FROM UNNEST(interest_entities.aliases || EXCLUDED.aliases) a
               )
             RETURNING id, canonical_name, category`,
            [parsed.canonical_name, parsed.aliases, parsed.category]
          );

          if (rows[0]) {
            logger.info(
              { text, canonical: rows[0].canonical_name, aliases: parsed.aliases.length },
              'Tier 3 Wikipedia match — entity saved'
            );
            return {
              entity_id:      rows[0].id,
              canonical_name: rows[0].canonical_name,
              category:       rows[0].category,
              confidence:     'wikipedia',
              genre_tags:     parsed.genre_tags,
            };
          }
        }
      }
    } catch (err) {
      logger.warn({ err, text }, 'Tier 3 Wikipedia lookup failed');
    }
  }

  // Không tìm ra gì
  return { entity_id: null, canonical_name: null, category: null, confidence: 'none' };
}

module.exports = { lookupEntity, exactMatch };
