const { query } = require('../config/db');

const SIMILARITY_THRESHOLD = 0.65;

/** Encode (score, id) pair into a base64 cursor string. */
function encodeCursor(score, id) {
  return Buffer.from(JSON.stringify({ score, id })).toString('base64');
}

/** Decode base64 cursor. Returns { score, id } or null if invalid. */
function decodeCursor(cursor) {
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64').toString('utf8'));
    if (typeof parsed.score !== 'number' || typeof parsed.id !== 'string') return null;
    return parsed;
  } catch {
    return null;
  }
}

/**
 * Recommendation feed từ user_embedding_chunks:
 * taste vector = profile chunk của viewer, so cosine với chunk của từng post
 * (mỗi post đúng 1 chunk). Supports cursor-based pagination via
 * (score DESC, id DESC) keyset.
 */
async function getRecommendedFeed(userId, { mode, cursor = null, limit = 20 } = {}) {
  // Taste vector: profile chunk của viewer (build khi onboarding/sửa hồ sơ)
  const { rows: vecRows } = await query(
    `SELECT embedding::text AS vec
     FROM user_embedding_chunks
     WHERE user_id = $1 AND source_type = 'user_profile'
     LIMIT 1`,
    [userId]
  );
  if (!vecRows[0]?.vec) return { posts: [], nextCursor: null };

  const params = [vecRows[0].vec, mode, limit + 1, userId]; // $4 = viewer

  // Decode cursor for keyset pagination
  const decoded     = cursor ? decodeCursor(cursor) : null;
  let cursorClause  = '';
  if (decoded) {
    params.push(decoded.score);
    const scoreIdx = params.length;
    params.push(decoded.id);
    const idIdx = params.length;
    cursorClause = `AND (score < $${scoreIdx} OR (score = $${scoreIdx} AND id < $${idIdx}::uuid))`;
  }

  const sql = `
    WITH ranked AS (
      SELECT
        p.id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls,
        p.article_title, p.link_url,
        p.like_count, p.comment_count, p.share_count, p.created_at,
        p.post_type, p.is_pinned, p.pinned_at,
        EXISTS(
          SELECT 1 FROM post_likes pl
          WHERE pl.post_id = p.id AND pl.user_id = $4::uuid
        ) AS is_liked,
        (1 - (c.embedding <=> $1::vector))::float AS score,
        json_build_object(
          'id',           u.id,
          'username',     u.username,
          'display_name', u.display_name,
          'avatar_color', u.avatar_color,
          'avatar_url',   u.avatar_url,
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
        AND NOT EXISTS (
          SELECT 1 FROM user_blocks ub
          WHERE (ub.blocker_id = $4::uuid AND ub.blocked_id = p.author_id)
             OR (ub.blocker_id = p.author_id AND ub.blocked_id = $4::uuid)
        )
        AND (
          p.privacy = 'public'
          OR p.author_id = $4::uuid
          OR (p.privacy = 'friends' AND EXISTS (
            SELECT 1 FROM connections co
            WHERE co.status = 'accepted'
              AND ((co.requester_id = p.author_id AND co.addressee_id = $4::uuid)
                OR (co.addressee_id = p.author_id AND co.requester_id = $4::uuid))
          ))
        )
        AND (1 - (c.embedding <=> $1::vector)) >= ${SIMILARITY_THRESHOLD}
      GROUP BY p.id, u.id, c.id
    )
    SELECT * FROM ranked
    WHERE 1 = 1 ${cursorClause}
    ORDER BY score DESC, id DESC
    LIMIT $3
  `;

  const { rows } = await query(sql, params);

  const hasMore = rows.length > limit;
  const posts   = hasMore ? rows.slice(0, limit) : rows;

  const nextCursor = hasMore
    ? encodeCursor(posts[posts.length - 1].score, posts[posts.length - 1].id)
    : null;

  return { posts, nextCursor };
}

module.exports = { getRecommendedFeed };
