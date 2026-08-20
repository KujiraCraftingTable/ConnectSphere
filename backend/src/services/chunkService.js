/**
 * chunkService.js
 *
 * Chunk-based embedding pipeline (replaces userVectorService + postEmbedService).
 * Each row in user_embedding_chunks is one embeddable unit of meaning:
 *   - 'user_profile' (source_id NULL): normalized profile fields — interests,
 *     skills, bio, job, company, location
 *   - 'post' (source_id = posts.id):   one post's content + article title + tags
 *
 * Interest/skill/tag terms are canonicalized through the entity registry
 * (Tier-1 exact match only — pure SQL, no Ollama call) so aliases embed with
 * their canonical name attached: "KNY" → "KNY (Kimetsu no Yaiba)". This is
 * required because mxbai-embed-large cannot resolve abbreviations or
 * Vietnamese titles on its own (measured ≈ noise floor).
 */

const { query } = require('../config/db');
const { embedText, translateToEnglish } = require('./aiService');
const { exactMatch } = require('./entityLookupService');
const logger = require('../utils/logger');

const MODEL_NAME = 'mxbai-embed-large';

/** Attach canonical name when the term is a known alias. Never throws. */
async function canonicalizeTerm(term) {
  try {
    const entity = await exactMatch(term, null);
    if (entity && entity.canonical_name.trim().toLowerCase() !== term.trim().toLowerCase()) {
      return `${term} (${entity.canonical_name})`;
    }
  } catch (err) {
    logger.debug({ err, term }, 'chunkService: canonicalize failed');
  }
  return term;
}

/** Canonicalize a list of terms in parallel. */
function canonicalizeAll(terms) {
  return Promise.all((terms ?? []).map(canonicalizeTerm));
}

/** Embed text and upsert one chunk row. sourceId NULL = profile chunk. */
async function upsertChunk({ userId, sourceType, sourceId, chunkIndex = 0, topic = null, content }) {
  const embedding = await embedText(content);
  if (!embedding) {
    logger.warn({ userId, sourceType, sourceId }, 'chunkService: embed failed');
    return false;
  }
  const vecLiteral = `[${embedding.join(',')}]`;

  // Two upsert paths because uniqueness is enforced by two partial indexes
  // (a plain UNIQUE would treat NULL source_id rows as always-distinct).
  if (sourceId === null) {
    await query(
      `INSERT INTO user_embedding_chunks
         (user_id, source_type, source_id, chunk_index, topic, content, embedding, model_name)
       VALUES ($1, $2, NULL, $3, $4, $5, $6::vector, $7)
       ON CONFLICT (user_id, source_type, chunk_index) WHERE source_id IS NULL
       DO UPDATE SET topic = EXCLUDED.topic, content = EXCLUDED.content,
                     embedding = EXCLUDED.embedding, model_name = EXCLUDED.model_name`,
      [userId, sourceType, chunkIndex, topic, content, vecLiteral, MODEL_NAME]
    );
  } else {
    await query(
      `INSERT INTO user_embedding_chunks
         (user_id, source_type, source_id, chunk_index, topic, content, embedding, model_name)
       VALUES ($1, $2, $3, $4, $5, $6, $7::vector, $8)
       ON CONFLICT (user_id, source_type, source_id, chunk_index) WHERE source_id IS NOT NULL
       DO UPDATE SET topic = EXCLUDED.topic, content = EXCLUDED.content,
                     embedding = EXCLUDED.embedding, model_name = EXCLUDED.model_name`,
      [userId, sourceType, sourceId, chunkIndex, topic, content, vecLiteral, MODEL_NAME]
    );
  }
  return true;
}

// ─── user_profile chunk ───────────────────────────────────────────────────────

/** Build (or rebuild) the profile chunk for a user. Returns true on success. */
async function buildProfileChunk(userId) {
  const { rows } = await query(
    `SELECT u.bio, u.job_title, u.company, u.location,
            COALESCE(json_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), '[]') AS interests,
            COALESCE(json_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), '[]') AS skills
     FROM users u
     LEFT JOIN user_interests ui ON ui.user_id = u.id
     LEFT JOIN user_skills    us ON us.user_id = u.id
     WHERE u.id = $1
     GROUP BY u.id`,
    [userId]
  );
  const profile = rows[0];
  if (!profile) return false;

  // interests/skills canonicalize (đã tiếng Anh); bio là free-text VN → dịch EN
  const [interests, skills, bioEn] = await Promise.all([
    canonicalizeAll(profile.interests),
    canonicalizeAll(profile.skills),
    translateToEnglish(profile.bio),
  ]);

  const parts = [];
  if (interests.length)     parts.push(`Interests: ${interests.join(', ')}`);
  if (skills.length)        parts.push(`Skills: ${skills.join(', ')}`);
  if (bioEn)                parts.push(`Bio: ${bioEn}`);
  if (profile.job_title)    parts.push(`Job: ${profile.job_title}`);
  if (profile.company)      parts.push(`Company: ${profile.company}`);
  if (profile.location)     parts.push(`Location: ${profile.location}`);

  const content = parts.join('\n');
  if (!content) {
    // Empty profile → remove any stale chunk so search never matches it
    await deleteProfileChunk(userId);
    return false;
  }

  return upsertChunk({ userId, sourceType: 'user_profile', sourceId: null, content });
}

/** Remove the profile chunk (empty profile or deleted account). */
async function deleteProfileChunk(userId) {
  await query(
    `DELETE FROM user_embedding_chunks WHERE user_id = $1 AND source_type = 'user_profile'`,
    [userId]
  );
}

// ─── post chunk ───────────────────────────────────────────────────────────────

/** Build (or rebuild) the chunk for one post. Returns true on success. */
async function buildPostChunk(postId) {
  const { rows } = await query(
    `SELECT p.author_id, p.content, p.article_title, p.status,
            COALESCE(array_agg(pt.tag) FILTER (WHERE pt.tag IS NOT NULL), '{}') AS tags
     FROM posts p
     LEFT JOIN post_tags pt ON pt.post_id = p.id
     WHERE p.id = $1
     GROUP BY p.id`,
    [postId]
  );
  const post = rows[0];

  // Post gone or hidden → chunk must not exist either
  if (!post || post.status !== 'posted') {
    await deletePostChunks(postId);
    return false;
  }

  // Free-text VN (content + article title) → dịch EN; tags canonicalize (đã EN)
  const naturalText = [post.content, post.article_title].filter(Boolean).join('. ');
  const [contentEn, tags] = await Promise.all([
    translateToEnglish(naturalText),
    canonicalizeAll(post.tags),
  ]);

  const parts = [];
  if (contentEn)   parts.push(`Content: ${contentEn}`);
  if (tags.length) parts.push(`Topics: ${tags.join(', ')}`);

  const content = parts.join('\n');
  if (!content) return false; // image-only post: nothing embeddable

  return upsertChunk({
    userId:     post.author_id,
    sourceType: 'post',
    sourceId:   postId,
    topic:      post.tags[0] ?? null,
    content,
  });
}

/** Remove chunks of a deleted / soft-deleted post. */
async function deletePostChunks(postId) {
  await query(
    `DELETE FROM user_embedding_chunks WHERE source_type = 'post' AND source_id = $1`,
    [postId]
  );
}

module.exports = { buildProfileChunk, deleteProfileChunk, buildPostChunk, deletePostChunks };
