const { query } = require('../config/db');
const { personaExpr } = require('../utils/personaSql');

// ─── Ranking knobs (chỉnh ở đây, không rải hằng số trong SQL) ─────────────────
const W_SEMANTIC        = 0.50;  // trọng số độ hợp sở thích
const W_RECENCY         = 0.35;  // trọng số độ mới
const W_ENGAGEMENT      = 0.15;  // trọng số tương tác (like/comment)
const CONNECTION_BOOST  = 0.15;  // cộng thẳng cho bài của người đã kết nối
const DISCOVERY_THRESHOLD = 0.65; // ngưỡng semantic CHỈ áp cho bài người lạ
const RECENCY_TAU_HOURS = 72;    // hằng số phân rã ~3 ngày
const ENGAGEMENT_CAP    = 500;   // mức tương tác coi như "tối đa" để chuẩn hoá

// ─── Taste vector = hồ sơ + hành vi ───────────────────────────────────────────
const W_PROFILE   = 0.6;  // trọng số các chunk hồ sơ
const W_BEHAVIOR  = 0.4;  // trọng số chunk của các bài đã thích
const RECENT_LIKES = 20;  // số bài đã thích gần nhất dùng để dựng taste

/** Encode (score, id) pair into a base64 cursor string.
 *  relaxed = true → các trang sau tiếp tục bỏ hard threshold (feed đã nới). */
function encodeCursor(score, id, relaxed = false) {
  return Buffer.from(JSON.stringify(
    relaxed ? { score, id, relaxed: true } : { score, id }
  )).toString('base64');
}

/** Decode base64 cursor. Returns { score, id, relaxed } or null if invalid. */
function decodeCursor(cursor) {
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64').toString('utf8'));
    if (typeof parsed.score !== 'number' || typeof parsed.id !== 'string') return null;
    return { score: parsed.score, id: parsed.id, relaxed: parsed.relaxed === true };
  } catch {
    return null;
  }
}

/** Parse pgvector text literal '[a,b,...]' thành mảng số. */
function parseVec(text) {
  return text.slice(1, -1).split(',').map(Number);
}

/** Trung bình cộng theo từng chiều của một danh sách vector. */
function meanVec(vectors) {
  const dim = vectors[0].length;
  const out = new Array(dim).fill(0);
  for (const v of vectors) for (let i = 0; i < dim; i++) out[i] += v[i];
  for (let i = 0; i < dim; i++) out[i] /= vectors.length;
  return out;
}

/** Chuẩn hoá L2 để cosine ổn định (vector 0 giữ nguyên). */
function normalize(v) {
  let norm = 0;
  for (const x of v) norm += x * x;
  norm = Math.sqrt(norm);
  return norm === 0 ? v : v.map(x => x / norm);
}

/** Định dạng mảng số về literal pgvector '[a,b,...]'. */
function toVectorLiteral(v) {
  return `[${v.join(',')}]`;
}

/**
 * Dựng taste vector của viewer:
 *   taste = W_PROFILE × tb(profile chunks) + W_BEHAVIOR × tb(chunk bài đã thích),
 * rồi chuẩn hoá L2. Trả null khi user chưa có dữ liệu nào (cold start).
 */
async function buildTasteVector(userId) {
  const { rows: profileRows } = await query(
    `SELECT embedding::text AS vec
       FROM user_embedding_chunks
      WHERE user_id = $1 AND source_type = 'user_profile'`,
    [userId]
  );
  const { rows: likedRows } = await query(
    `SELECT c.embedding::text AS vec
       FROM post_likes pl
       JOIN user_embedding_chunks c
         ON c.source_type = 'post' AND c.source_id = pl.post_id
      WHERE pl.user_id = $1
      ORDER BY pl.created_at DESC
      LIMIT $2`,
    [userId, RECENT_LIKES]
  );

  const profileVecs = profileRows.map(r => parseVec(r.vec));
  const likedVecs   = likedRows.map(r => parseVec(r.vec));

  if (!profileVecs.length && !likedVecs.length) return null;

  let taste;
  if (profileVecs.length && likedVecs.length) {
    const p = meanVec(profileVecs);
    const b = meanVec(likedVecs);
    taste = p.map((x, i) => W_PROFILE * x + W_BEHAVIOR * b[i]);
  } else {
    taste = meanVec(profileVecs.length ? profileVecs : likedVecs);
  }
  return normalize(taste);
}

/**
 * Personalized newsfeed từ user_embedding_chunks.
 *
 * Hai "pool" gộp trong một truy vấn:
 *   • Bài của connection (accepted, đúng mode): LUÔN giữ, bỏ qua ngưỡng semantic.
 *   • Bài người lạ (discovery): chỉ giữ khi semantic ≥ DISCOVERY_THRESHOLD.
 * Xếp hạng blend: W_SEMANTIC×sim + W_RECENCY×decay + W_ENGAGEMENT×eng + boost.
 * Cold start (chưa có taste) → xếp thuần recency+engagement để không rỗng.
 * Bài của chính viewer bị loại (chỉ hiện ở profile). Keyset cursor (score, id).
 */
async function getRecommendedFeed(userId, { mode, cursor = null, limit = 20 } = {}) {
  const taste    = await buildTasteVector(userId);
  const hasTaste = taste !== null;

  // $1 = viewer, $2 = mode, $3 = limit (+1 để biết còn trang sau)
  const params = [userId, mode, limit + 1];

  let semanticExpr = '0::float';
  if (hasTaste) {
    params.push(toVectorLiteral(taste));
    semanticExpr = `(1 - (c.embedding <=> $${params.length}::vector))::float`;
  }

  // Keyset pagination trên (score DESC, id DESC)
  const decoded    = cursor ? decodeCursor(cursor) : null;
  let cursorClause = '';
  if (decoded) {
    params.push(decoded.score);
    const scoreIdx = params.length;
    params.push(decoded.id);
    const idIdx = params.length;
    cursorClause = `AND (score < $${scoreIdx} OR (score = $${scoreIdx} AND id < $${idIdx}::uuid))`;
  }

  // Người lạ phải vượt ngưỡng; connection luôn giữ. Cold start: giữ tất cả.
  // relaxed (từ cursor): trang đầu đã phải nới ngưỡng → các trang sau nới theo.
  let relaxed = decoded?.relaxed === true;
  const poolFilter = () => (hasTaste && !relaxed)
    ? `(is_connection OR semantic >= ${DISCOVERY_THRESHOLD})`
    : 'TRUE';

  const buildSql = () => `
    WITH scored AS (
      SELECT
        p.id, p.content, p.mode, p.privacy,
        p.image_urls[1] AS image_url, p.image_urls, p.article_title, p.link_url,
        p.like_count, p.comment_count, p.share_count, p.created_at,
        p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id,
        EXISTS(
          SELECT 1 FROM post_likes pl
          WHERE pl.post_id = p.id AND pl.user_id = $1::uuid
        ) AS is_liked,
        EXISTS(
          SELECT 1 FROM connections co
          WHERE co.status = 'accepted' AND co.mode = $2
            AND ((co.requester_id = p.author_id AND co.addressee_id = $1::uuid)
              OR (co.addressee_id = p.author_id AND co.requester_id = $1::uuid))
        ) AS is_connection,
        ${semanticExpr} AS semantic,
        EXP(- (EXTRACT(EPOCH FROM (NOW() - p.created_at)) / 3600.0) / ${RECENCY_TAU_HOURS})::float AS recency,
        LEAST(1, LN(1 + p.like_count + 2 * p.comment_count) / LN(1 + ${ENGAGEMENT_CAP}))::float AS engagement,
        CASE WHEN p.shared_post_id IS NOT NULL THEN (
          SELECT json_build_object(
            'id',            sp.id,
            'content',       sp.content,
            'image_url',     sp.image_urls[1],
            'image_urls',    sp.image_urls,
            'link_url',      sp.link_url,
            'article_title', sp.article_title,
            'created_at',    sp.created_at,
            'author', json_build_object(
              'id',           su.id,
              'username',     su.username,
              'display_name', ${personaExpr('display_name', 'sp.mode', 'su')},
              'avatar_color', su.avatar_color,
              'avatar_url',   ${personaExpr('avatar_url', 'sp.mode', 'su')}
            )
          )
          FROM posts sp
          JOIN users su ON su.id = sp.author_id
          WHERE sp.id = p.shared_post_id AND sp.status = 'posted'
        ) ELSE NULL END AS shared_post,
        json_build_object(
          'id',           u.id,
          'username',     u.username,
          'display_name', ${personaExpr('display_name', 'p.mode')},
          'avatar_color', u.avatar_color,
          'avatar_url',   ${personaExpr('avatar_url', 'p.mode')},
          'job_title',    u.job_title,
          'company',      u.company
        ) AS author,
        COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL), '[]') AS tags
      FROM user_embedding_chunks c
      JOIN posts p ON p.id = c.source_id
      JOIN users u ON u.id = p.author_id
      LEFT JOIN post_tags pt ON pt.post_id = p.id
      WHERE c.source_type = 'post'
        AND p.mode = $2
        AND p.status = 'posted'
        AND p.community_id IS NULL
        AND p.author_id <> $1::uuid
        AND NOT EXISTS (
          SELECT 1 FROM user_blocks ub
          WHERE (ub.blocker_id = $1::uuid AND ub.blocked_id = p.author_id)
             OR (ub.blocker_id = p.author_id AND ub.blocked_id = $1::uuid)
        )
        AND NOT EXISTS (
          SELECT 1 FROM hidden_posts hp
          WHERE hp.user_id = $1::uuid AND hp.post_id = p.id
        )
        AND (
          p.privacy = 'public'
          OR (p.privacy = 'friends' AND EXISTS (
            SELECT 1 FROM connections cf
            WHERE cf.status = 'accepted'
              AND ((cf.requester_id = p.author_id AND cf.addressee_id = $1::uuid)
                OR (cf.addressee_id = p.author_id AND cf.requester_id = $1::uuid))
          ))
        )
      GROUP BY p.id, u.id, c.id
    ),
    ranked AS (
      SELECT *,
        (
          ${W_SEMANTIC} * semantic
          + ${W_RECENCY} * recency
          + ${W_ENGAGEMENT} * engagement
          + CASE WHEN is_connection THEN ${CONNECTION_BOOST} ELSE 0 END
        )::float AS score
      FROM scored
      WHERE ${poolFilter()}
    )
    SELECT * FROM ranked
    WHERE 1 = 1 ${cursorClause}
    ORDER BY score DESC, id DESC
    LIMIT $3
  `;

  let { rows } = await query(buildSql(), params);

  // Chống feed rỗng: user có taste nhưng không bài nào đạt ngưỡng discovery
  // (thường là user mới — taste mỏng, chưa có connection) → chạy lại trang đầu
  // bỏ hard threshold; semantic vẫn tham gia xếp hạng nên bài gần khẩu vị nhất
  // vẫn lên trước. Cursor các trang sau mang cờ relaxed để giữ nhất quán.
  if (rows.length === 0 && hasTaste && !relaxed && !decoded) {
    relaxed = true;
    ({ rows } = await query(buildSql(), params));
  }

  const hasMore = rows.length > limit;
  const posts   = hasMore ? rows.slice(0, limit) : rows;

  const nextCursor = hasMore
    ? encodeCursor(posts[posts.length - 1].score, posts[posts.length - 1].id, relaxed)
    : null;

  return { posts, nextCursor };
}

module.exports = { getRecommendedFeed };
