const { query } = require('../config/db');

const DATING_KEYWORDS = new Set([
  'hẹn hò', 'dating', 'người yêu', 'partner', 'bạn đời',
  'tình cảm', 'love', 'romantic', 'date', 'yêu', 'crush',
  'bạn trai', 'bạn gái', 'tìm người yêu',
]);

// ── Retrieval tuning knobs ────────────────────────────────────────────────────
const CHUNK_POOL_SIZE = 200;  // top-k chunk lấy từ HNSW trước khi group theo user
const W_MAX           = 0.7;  // trọng số chunk khớp nhất
const W_AVG           = 0.3;  // trọng số "điểm chuyên cần" — avg top-3 chunk (÷3 cố định)
const W_RETRIEVAL     = 0.85; // rerank: phần điểm retrieval
const W_PERSONAL      = 0.15; // rerank: phần cá nhân hóa (profile chunk similarity)

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
 *      (chia cố định cho 3: khớp ở nhiều nguồn mới được trọn phần này)
 *   3. Hard filters at user level (mode, location, gender, radius, blocks…)
 *   4. Personalization rerank: score = W_RETRIEVAL×retrieval + W_PERSONAL×sim(
 *      profile chunk của người tìm, profile chunk ứng viên) — bỏ qua nếu thiếu
 *
 * interestGroups: [[String]] — each inner array is OR'd, outer arrays are AND'd.
 */
async function vectorSearch({
  queryVector,
  mode           = null,
  location       = null,
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
  const searcherRef = p(excludeUserId); // NULL → personalization tự tắt

  const wheres = [];

  if (mode)          wheres.push(`u.default_mode = ${p(mode)}`);
  if (excludeUserId) {
    wheres.push(`u.id != ${searcherRef}::uuid`);
    // Loại user đã chặn/bị chặn (2 chiều) so với người tìm
    wheres.push(`NOT EXISTS (
      SELECT 1 FROM user_blocks ub
      WHERE (ub.blocker_id = ${searcherRef}::uuid AND ub.blocked_id = u.id)
         OR (ub.blocker_id = u.id AND ub.blocked_id = ${searcherRef}::uuid)
    )`);
  }

  if (location) {
    wheres.push(`u.location ILIKE ${p('%' + location + '%')}`);
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

  if (hasDatingIntent && currentUserGender) {
    const targetGender =
      currentUserGender === 'male'   ? 'female' :
      currentUserGender === 'female' ? 'male'   : 'other';
    wheres.push(`u.gender = ${p(targetGender)}`);
  }

  const userFilter = wheres.length ? `WHERE ${wheres.join(' AND ')}` : '';

  const sql = `
    WITH chunk_pool AS (
      -- HNSW scan: k chunk gần nhất, chưa lọc threshold để index được dùng tối đa
      SELECT c.user_id, (1 - (c.embedding <=> ${vecRef}::vector))::float AS sim
      FROM user_embedding_chunks c
      ORDER BY c.embedding <=> ${vecRef}::vector
      LIMIT ${CHUNK_POOL_SIZE}
    ),
    hits AS (
      SELECT user_id, sim,
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
    personal AS (
      -- similarity giữa profile chunk của người tìm và của từng ứng viên
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
      u.id, u.username, u.display_name, u.bio, u.avatar_color, u.avatar_url,
      u.location, u.job_title, u.company, u.default_mode, u.gender,
      u.follower_count, u.following_count, u.post_count,
      COALESCE(json_agg(DISTINCT ui2.interest) FILTER (WHERE ui2.interest IS NOT NULL), '[]') AS interests,
      COALESCE(json_agg(DISTINCT us2.skill)    FILTER (WHERE us2.skill    IS NOT NULL), '[]') AS skills,
      COALESCE(
        ${W_RETRIEVAL} * s.retrieval_score + ${W_PERSONAL} * pr.profile_sim,
        s.retrieval_score
      )::float AS score
    FROM user_scores s
    JOIN users u ON u.id = s.user_id
    LEFT JOIN personal       pr  ON pr.user_id = s.user_id
    LEFT JOIN user_interests ui2 ON ui2.user_id = u.id
    LEFT JOIN user_skills    us2 ON us2.user_id = u.id
    ${userFilter}
    GROUP BY u.id, s.retrieval_score, pr.profile_sim
    ORDER BY score DESC
    LIMIT 20
  `;

  const { rows } = await query(sql, params);
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

/** Append one search query to the log table (fire-and-forget). */
async function logSearch(userQuery, mode) {
  await query(
    'INSERT INTO search_logs (query, mode) VALUES ($1, $2)',
    [userQuery, mode ?? null]
  );
}

module.exports = {
  vectorSearch,
  logSearch,
  getUserContext,
  matchesInterestGroups,
  DATING_KEYWORDS,
};
