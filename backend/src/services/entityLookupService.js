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
const EMBED_MODEL             = 'mxbai-embed-large';
const HIGH_CONFIDENCE_THRESHOLD = 0.8;  // ≥ ngưỡng này: tự tin, auto-save alias
const SUGGEST_THRESHOLD         = 0.6;  // [0.6, 0.8): vùng xám, gợi ý cho user confirm

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

/**
 * Top-k entity candidates by cosine similarity — pure read, KHÔNG side-effect.
 * Returns [{ entity_id, canonical_name, category, similarity }] sorted desc.
 */
async function findEntityCandidates(text, category = null, limit = 3) {
  let embedding;
  try {
    embedding = await embedText(text);
  } catch (err) {
    logger.warn({ err }, 'Embed failed — skipping vector tier');
    return [];
  }

  const vecLiteral = `[${embedding.join(',')}]`;

  const { rows } = await query(
    `SELECT id AS entity_id, canonical_name, category,
            1 - (embedding <=> $1::vector) AS similarity
     FROM interest_entities
     WHERE embedding IS NOT NULL
       AND ($2::text IS NULL OR category = $2)
     ORDER BY embedding <=> $1::vector
     LIMIT $3`,
    [vecLiteral, category || null, limit]
  );

  return rows.map((r) => ({ ...r, similarity: parseFloat(r.similarity) }));
}

/** Append keyword vào aliases của một entity (idempotent). Returns entity hoặc null. */
async function saveAlias(keyword, entityId) {
  const alias = keyword?.trim();
  if (!alias) return null;

  const { rows } = await query(
    `SELECT id, canonical_name, aliases FROM interest_entities WHERE id = $1`,
    [entityId]
  );
  const entity = rows[0];
  if (!entity) return null;

  if (!entity.aliases.map((a) => a.toLowerCase()).includes(alias.toLowerCase())) {
    await query(
      `UPDATE interest_entities SET aliases = array_append(aliases, $1) WHERE id = $2`,
      [alias, entityId]
    );
    logger.info({ alias, canonical: entity.canonical_name }, 'New alias saved (confirmed)');
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

  // Tier 2 — Vector similarity. Chỉ auto-match + auto-save khi TỰ TIN (≥ 0.8).
  // Vùng xám (0.6–0.8) KHÔNG tự quyết ở đây — search path sẽ hỏi user confirm.
  const [top] = await findEntityCandidates(text, category, 1);
  if (top && top.similarity >= HIGH_CONFIDENCE_THRESHOLD) {
    logger.debug({ text, match: top.canonical_name, sim: top.similarity }, 'Tier 2 confident match');
    // Save alias fire-and-forget — không block response, lỗi chỉ log warn
    saveAlias(text, top.entity_id)
      .catch((err) => logger.warn({ err, text }, 'saveAlias failed after vector match'));
    return {
      entity_id:      top.entity_id,
      canonical_name: top.canonical_name,
      category:       top.category,
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

module.exports = {
  lookupEntity, exactMatch, findEntityCandidates, saveAlias,
  HIGH_CONFIDENCE_THRESHOLD, SUGGEST_THRESHOLD,
};
