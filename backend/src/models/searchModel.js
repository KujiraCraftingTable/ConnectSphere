const { query } = require('../config/db');
const { personaCols, personaSetupClause } = require('../utils/personaSql');
const logger = require('../utils/logger');

const DATING_KEYWORDS = new Set([
  'hẹn hò', 'dating', 'người yêu', 'partner', 'bạn đời',
  'tình cảm', 'love', 'romantic', 'date', 'yêu', 'crush',
  'bạn trai', 'bạn gái', 'tìm người yêu',
]);

// ── Retrieval tuning knobs ────────────────────────────────────────────────────
const CHUNK_POOL_SIZE = 200;  // top-k chunks pulled from HNSW before grouping by user
const W_MAX           = 0.7;  // weight for the best-matching chunk
const W_AVG           = 0.3;  // weight for the "consistency score" — avg of top-3 chunks (fixed ÷3)
const W_RETRIEVAL     = 0.85; // rerank: retrieval score portion
const W_PERSONAL      = 0.15; // rerank: personalization portion (profile chunk similarity)
const EVIDENCE_PER_USER = 5;  // max "match reasons" per user (mini CV) — capped again at the controller

/** Fetch gender and location of a user — used for contextual search filtering. */
async function getUserContext(userId) {
  const { rows } = await query(
    'SELECT gender, location FROM users WHERE id = $1',
    [userId]
  );
  return rows[0] ?? null;
}

/**
 * Chunk-based vector search.
 *
 * Pipeline (per approved design):
 *   1. Top-k nearest chunks to queryVector (HNSW), filtered by chunk threshold
 *   2. Group chunks by user → retrieval_score = W_MAX×max + W_AVG×(sum top-3 / 3)
 *      (fixed divide by 3: only matching across multiple sources earns this full share)
 *   3. Hard filters at user level (mode, location, gender, radius, blocks…)
 *   4. Personalization rerank: score = W_RETRIEVAL×retrieval + W_PERSONAL×sim(
 *      searcher's profile chunk, candidate's profile chunk) — skipped when missing
 *
 * interestGroups: [[String]] — each inner array is OR'd, outer arrays are AND'd.
 */
async function vectorSearch({
  queryVector,
  mode           = null,
  location       = null,
  targetGender   = null,
  targetAgeMin   = null,
  targetAgeMax   = null,
  hasDatingIntent = false,
  currentUserGender = null,
  searchCoords   = null,
  radiusKm       = null,
  threshold      = 0.6,
  excludeUserId  = null,
  interestGroups = null,
}) {
  const params = [];
  const p = (val) => { params.push(val); return `$${params.length}`; };

  const vecRef      = p(`[${queryVector.join(',')}]`);
  const searcherRef = p(excludeUserId); // NULL → personalization automatically turns off

  const wheres = [];

  // Only return users who've set up the persona for the mode being searched — not set up = invisible
  const modeRef = mode ? p(mode) : null;
  if (modeRef) wheres.push(personaSetupClause(modeRef));
  if (excludeUserId) {
    wheres.push(`u.id != ${searcherRef}::uuid`);
    // Excludes users who are blocked/blocking (both directions) relative to the searcher
    wheres.push(`NOT EXISTS (
      SELECT 1 FROM user_blocks ub
      WHERE (ub.blocker_id = ${searcherRef}::uuid AND ub.blocked_id = u.id)
         OR (ub.blocker_id = u.id AND ub.blocked_id = ${searcherRef}::uuid)
    )`);
    // Excludes people already connected (accepted) with the searcher in the current mode —
    // no need to suggest someone who's already a friend/colleague
    wheres.push(`NOT EXISTS (
      SELECT 1 FROM connections c
      WHERE c.status = 'accepted'
        ${mode ? `AND c.mode = ${p(mode)}` : ''}
        AND (
          (c.requester_id = ${searcherRef}::uuid AND c.addressee_id = u.id)
          OR (c.requester_id = u.id AND c.addressee_id = ${searcherRef}::uuid)
        )
    )`);
  }

  if (location) {
    // Normalize both sides: strip "city"/"province", strip spaces, lowercase — so
    // "Ho Chi Minh City" (criteria/seed) matches "Ho Chi Minh" (app), and "Ha Noi City"
    // matches "Hanoi". SQL and JS normalize identically.
    const sqlNorm = (col) =>
      `REPLACE(REPLACE(REPLACE(LOWER(${col}), ' city', ''), ' province', ''), ' ', '')`;
    const jsNorm = (s) =>
      s.toLowerCase().replace(/ city/g, '').replace(/ province/g, '').replace(/ /g, '');
    wheres.push(`${sqlNorm('u.location')} LIKE ${p('%' + jsNorm(location) + '%')}`);
  }

  if (searchCoords && radiusKm) {
    const lngRef = p(searchCoords.lng);
    const latRef = p(searchCoords.lat);
    const radRef = p(radiusKm);
    wheres.push(
      `EXISTS (` +
        `SELECT 1 FROM vn_wards w ` +
        `WHERE w.id = u.ward_id ` +
        `AND (6371 * acos(` +
          `cos(radians(${latRef})) * cos(radians(w.lat)) * ` +
          `cos(radians(w.lng) - radians(${lngRef})) + ` +
          `sin(radians(${latRef})) * sin(radians(w.lat))` +
        `)) <= ${radRef}` +
      `)`
    );
  }

  // Hard filter by interest groups — AND between groups, OR within each group.
  // Each keyword is matched bidirectionally (substring in either direction).
  if (interestGroups?.length) {
    for (const group of interestGroups) {
      if (!group?.length) continue;
      const orParts = group.map(kw => {
        const k        = kw.toLowerCase();
        const likeRef  = p(`%${k}%`);   // user interest contains keyword
        const kwRef    = p(k);           // keyword contains user interest
        return `(LOWER(uix.interest) LIKE ${likeRef} OR ${kwRef} LIKE '%' || LOWER(uix.interest) || '%')`;
      });
      wheres.push(
        `EXISTS (SELECT 1 FROM user_interests uix WHERE uix.user_id = u.id AND (${orParts.join(' OR ')}))`
      );
    }
  }

  // Gender filter: an explicit gender from the user ("male/female friend") beats the dating heuristic.
  if (targetGender) {
    wheres.push(`u.gender = ${p(targetGender)}`);
  } else if (hasDatingIntent && currentUserGender) {
    const opposite =
      currentUserGender === 'male'   ? 'female' :
      currentUserGender === 'female' ? 'male'   : 'other';
    wheres.push(`u.gender = ${p(opposite)}`);
  }

  // Age filter: explicit range/bound from the prompt — always matched against the
  // real age (dob_visibility only gates whether age is *displayed*, see result SELECT).
  if (targetAgeMin != null || targetAgeMax != null) {
    wheres.push(`u.age IS NOT NULL`);
    if (targetAgeMin != null) wheres.push(`u.age >= ${p(targetAgeMin)}`);
    if (targetAgeMax != null) wheres.push(`u.age <= ${p(targetAgeMax)}`);
  }

  const userFilter = wheres.length ? `WHERE ${wheres.join(' AND ')}` : '';

  // Number of mutual friends/connections with the searcher (INTERSECT the two sets
  // of accepted counterparts for the mode) — 0 when the searcher is unknown
  let mutualSelect = '0';
  if (excludeUserId) {
    const modeRef = mode ? p(mode) : null;
    mutualSelect = `(
      SELECT COUNT(*)::int FROM (
        SELECT CASE WHEN c.requester_id = ${searcherRef}::uuid THEN c.addressee_id ELSE c.requester_id END
        FROM connections c
        WHERE c.status = 'accepted'
          ${modeRef ? `AND c.mode = ${modeRef}` : ''}
          AND (c.requester_id = ${searcherRef}::uuid OR c.addressee_id = ${searcherRef}::uuid)
        INTERSECT
        SELECT CASE WHEN c.requester_id = u.id THEN c.addressee_id ELSE c.requester_id END
        FROM connections c
        WHERE c.status = 'accepted'
          ${modeRef ? `AND c.mode = ${modeRef}` : ''}
          AND (c.requester_id = u.id OR c.addressee_id = u.id)
      ) mutual
    )`;
  }

  const sql = `
    WITH chunk_pool AS (
      -- HNSW scan: k nearest chunks, no threshold filter yet so the index gets used to the fullest
      SELECT c.user_id, c.source_type, c.source_id, c.topic, c.content,
             (1 - (c.embedding <=> ${vecRef}::vector))::float AS sim
      FROM user_embedding_chunks c
      ORDER BY c.embedding <=> ${vecRef}::vector
      LIMIT ${CHUNK_POOL_SIZE}
    ),
    hits AS (
      SELECT user_id, source_type, source_id, topic, content, sim,
             ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY sim DESC) AS rn
      FROM chunk_pool
      WHERE sim >= ${p(threshold)}
    ),
    user_scores AS (
      SELECT user_id,
             (${W_MAX} * MAX(sim)
            + ${W_AVG} * (SUM(sim) FILTER (WHERE rn <= 3) / 3.0))::float AS retrieval_score
      FROM hits
      GROUP BY user_id
    ),
    evidence AS (
      -- "Match reasons" (mini CV): profile chunks are kept individually; posts are
      -- GROUPED by topic → 1 entry with the real post count + timestamps. A post only
      -- counts while it's still 'posted' and public (never leaks a private post).
      SELECT user_id, jsonb_agg(ev ORDER BY sim DESC) AS match_evidence
      FROM (
        SELECT h.user_id, h.sim,
               jsonb_build_object(
                 'source_type', h.source_type,
                 'topic',       h.topic,
                 'content',     h.content,
                 'similarity',  ROUND(h.sim::numeric, 4)
               ) AS ev
        FROM hits h
        WHERE h.source_type = 'user_profile'
        UNION ALL
        SELECT h.user_id, MAX(h.sim) AS sim,
               jsonb_build_object(
                 'source_type',    'post',
                 'topic',          h.topic,
                 'content',        string_agg(h.content, ' '),
                 'similarity',     ROUND(MAX(h.sim)::numeric, 4),
                 'post_count',     COUNT(*),
                 'latest_post_at', MAX(p2.created_at),
                 'oldest_post_at', MIN(p2.created_at)
               ) AS ev
        FROM hits h
        JOIN posts p2 ON p2.id = h.source_id
        WHERE h.source_type = 'post' AND p2.status = 'posted' AND p2.privacy = 'public'
        GROUP BY h.user_id, h.topic
      ) grouped
      GROUP BY user_id
    ),
    personal AS (
      -- similarity between the searcher's profile chunk and each candidate's
      SELECT pc.user_id,
             (1 - (pc.embedding <=> (
                SELECT embedding FROM user_embedding_chunks
                WHERE user_id = ${searcherRef}::uuid AND source_type = 'user_profile'
                LIMIT 1
             )))::float AS profile_sim
      FROM user_embedding_chunks pc
      WHERE pc.source_type = 'user_profile'
        AND pc.user_id IN (SELECT user_id FROM user_scores)
    )
    SELECT
      u.id, u.username,
      ${modeRef ? personaCols(modeRef) : 'u.display_name, u.bio, u.avatar_url, u.cover_url'},
      u.avatar_color,
      u.location, u.job_title, u.company, u.default_mode, u.gender,
      CASE WHEN u.dob_visibility = 'public' THEN u.age ELSE NULL END AS age,
      u.follower_count, u.following_count, u.post_count,
      COALESCE(json_agg(DISTINCT ui2.interest) FILTER (WHERE ui2.interest IS NOT NULL), '[]') AS interests,
      COALESCE(json_agg(DISTINCT us2.skill)    FILTER (WHERE us2.skill    IS NOT NULL), '[]') AS skills,
      COALESCE(
        ${W_RETRIEVAL} * s.retrieval_score + ${W_PERSONAL} * pr.profile_sim,
        s.retrieval_score
      )::float AS score,
      COALESCE(e.match_evidence, '[]'::jsonb) AS match_evidence,
      ${mutualSelect} AS mutual_count
    FROM user_scores s
    JOIN users u ON u.id = s.user_id
    LEFT JOIN evidence       e   ON e.user_id  = s.user_id
    LEFT JOIN personal       pr  ON pr.user_id = s.user_id
    LEFT JOIN user_interests ui2 ON ui2.user_id = u.id
    LEFT JOIN user_skills    us2 ON us2.user_id = u.id
    ${userFilter}
    GROUP BY u.id, s.retrieval_score, pr.profile_sim, e.match_evidence
    ORDER BY score DESC
    LIMIT 20
  `;

  const dbStart = Date.now();
  const { rows } = await query(sql, params);
  logger.info({ durationMs: Date.now() - dbStart, resultCount: rows.length }, 'AI search: vectorSearch done');
  return rows;
}

/**
 * Returns true if the user's interests satisfy ALL interest groups.
 * Within each group, only one keyword needs to match (OR).
 * Matching is case-insensitive substring in both directions.
 */
function matchesInterestGroups(userInterests, interestGroups) {
  if (!interestGroups?.length) return true;
  const lower = (userInterests ?? []).map(i => i.toLowerCase());
  return interestGroups.every(group =>
    group.some(kw => {
      const k = kw.toLowerCase();
      return lower.some(ui => ui.includes(k) || k.includes(ui));
    })
  );
}

/**
 * Community evidence for mini-CV reasons: public communities each user joined
 * whose name/description/tags match any search term (case-insensitive substring).
 * Returns Map<user_id, [community_name]> — max 2 communities per user.
 */
async function findCommunityEvidence(userIds, terms) {
  if (!userIds?.length || !terms?.length) return new Map();
  const patterns = terms.map(t => `%${t.toLowerCase()}%`);

  const { rows } = await query(
    `SELECT DISTINCT cm.user_id, c.name, c.member_count
     FROM community_members cm
     JOIN communities c ON c.id = cm.community_id
     WHERE cm.user_id = ANY($1::uuid[])
       AND c.privacy = 'public'
       AND (LOWER(c.name) LIKE ANY($2::text[])
            OR LOWER(COALESCE(c.description, '')) LIKE ANY($2::text[])
            OR EXISTS (
              SELECT 1 FROM community_tags ct
              WHERE ct.community_id = c.id AND LOWER(ct.tag) LIKE ANY($2::text[])
            ))
     ORDER BY cm.user_id, c.member_count DESC`,
    [userIds, patterns]
  );

  const byUser = new Map();
  for (const row of rows) {
    const list = byUser.get(row.user_id) ?? [];
    if (list.length < 2) list.push(row.name);
    byUser.set(row.user_id, list);
  }
  return byUser;
}

/** Append one search query to the log table (fire-and-forget). */
async function logSearch(userQuery, mode) {
  await query(
    'INSERT INTO search_logs (query, mode) VALUES ($1, $2)',
    [userQuery, mode ?? null]
  );
}

module.exports = {
  vectorSearch,
  findCommunityEvidence,
  logSearch,
  getUserContext,
  matchesInterestGroups,
  DATING_KEYWORDS,
  EVIDENCE_PER_USER,
};
