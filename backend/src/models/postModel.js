const { query } = require('../config/db');
const { personaExpr } = require('../utils/personaSql');

// Shared SELECT for post rows. `viewerRef` là placeholder SQL (vd '$1') chứa
// UUID của viewer (hoặc NULL) — luôn parameterized, không bao giờ nội suy chuỗi.
// Danh tính tác giả resolve theo persona của MODE BÀI VIẾT (p.mode/sp.mode) —
// bài hobby hiện tên hobby, bài work hiện tên work.
const buildPostSelect = (viewerRef) => `
  SELECT
    p.id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.article_title, p.link_url,
    p.like_count, p.comment_count, p.share_count, p.created_at,
    p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id,
    EXISTS(
      SELECT 1 FROM post_likes pl
      WHERE pl.post_id = p.id AND pl.user_id = ${viewerRef}::uuid
    ) AS is_liked,
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
    COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL), '[]') AS tags,
    json_build_object(
      'id',           u.id,
      'username',     u.username,
      'display_name', ${personaExpr('display_name', 'p.mode')},
      'avatar_color', u.avatar_color,
      'avatar_url',   ${personaExpr('avatar_url', 'p.mode')},
      'job_title',    u.job_title,
      'company',      u.company
    ) AS author,
    -- Poll/event payload — mirrors postModel.getPostsByCommunity so a single-post
    -- fetch (deep link, notification tap) returns the same data as the list view.
    -- 'id' inside event_data is community_events.id, distinct from the post id —
    -- required by POST /api/events/:id/rsvp which keys off the event id, not the post id.
    CASE WHEN p.post_type = 'event' THEN (
      SELECT json_build_object(
        'id',         ce.id,
        'title',      ce.title,
        'location',   ce.location,
        'starts_at',  ce.starts_at,
        'ends_at',    ce.ends_at,
        'rsvp_count', ce.rsvp_count,
        'user_rsvp',  (SELECT er.status FROM event_rsvps er
                        WHERE er.event_id = ce.id AND er.user_id = ${viewerRef}::uuid)
      )
      FROM community_events ce
      WHERE ce.post_id = p.id
    ) ELSE NULL END AS event_data,
    CASE WHEN p.post_type = 'poll' THEN
      json_build_object(
        'options', (
          SELECT json_agg(
            json_build_object(
              'id',         po.id,
              'text',       po.text,
              'vote_count', po.vote_count,
              'position',   po.position,
              'ends_at',    po.ends_at
            ) ORDER BY po.position
          )
          FROM poll_options po WHERE po.post_id = p.id
        ),
        'user_vote', (SELECT pv.poll_option_id::TEXT
                       FROM poll_votes pv
                       JOIN poll_options po2 ON po2.id = pv.poll_option_id
                       WHERE po2.post_id = p.id AND pv.user_id = ${viewerRef}::uuid)
      )
    ELSE NULL END AS poll_data
  FROM posts p
  JOIN  users     u  ON u.id = p.author_id
  LEFT JOIN post_tags pt ON pt.post_id = p.id
`;

// Quyền xem post: public, bài của chính mình, hoặc 'friends' khi hai bên đã
// accepted connection. 'only_me' chỉ tác giả thấy.
const privacyClause = (viewerRef) => `
  (
    p.privacy = 'public'
    OR p.author_id = ${viewerRef}::uuid
    OR (p.privacy = 'friends' AND EXISTS (
      SELECT 1 FROM connections c
      WHERE c.status = 'accepted'
        AND ((c.requester_id = p.author_id AND c.addressee_id = ${viewerRef}::uuid)
          OR (c.addressee_id = p.author_id AND c.requester_id = ${viewerRef}::uuid))
    ))
  )
`;

// Loại bài của user đã chặn/bị chặn (2 chiều) so với viewer
const notBlockedClause = (viewerRef) => `
  NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE (ub.blocker_id = ${viewerRef}::uuid AND ub.blocked_id = p.author_id)
       OR (ub.blocker_id = p.author_id AND ub.blocked_id = ${viewerRef}::uuid)
  )
`;

// Loại bài mà viewer đã bấm "Ẩn bài viết" (chỉ áp cho các query dạng danh sách;
// findById giữ nguyên để share embed / notification vẫn mở được bài)
const notHiddenClause = (viewerRef) => `
  NOT EXISTS (
    SELECT 1 FROM hidden_posts hp
    WHERE hp.user_id = ${viewerRef}::uuid AND hp.post_id = p.id
  )
`;

// Chỉ hiện bài của chính mình + của những người đã accepted connection
const connectionsOnlyClause = (viewerRef) => `
  (
    p.author_id = ${viewerRef}::uuid
    OR EXISTS (
      SELECT 1 FROM connections c2
      WHERE c2.status = 'accepted'
        AND ((c2.requester_id = p.author_id AND c2.addressee_id = ${viewerRef}::uuid)
          OR (c2.addressee_id = p.author_id AND c2.requester_id = ${viewerRef}::uuid))
    )
  )
`;

async function findAll({ mode, authorId, viewerId = null, tag = null, limit = 20, offset = 0, connectionsOnly = false }) {
  const params = [viewerId];
  let where = `WHERE p.status = 'posted' AND p.community_id IS NULL
    AND ${privacyClause('$1')} AND ${notBlockedClause('$1')} AND ${notHiddenClause('$1')}`;

  if (connectionsOnly) {
    where += ` AND ${connectionsOnlyClause('$1')}`;
  }
  if (mode) {
    params.push(mode);
    where += ` AND p.mode = $${params.length}`;
  }
  if (authorId) {
    params.push(authorId);
    where += ` AND p.author_id = $${params.length}`;
  }
  if (tag) {
    params.push(tag);
    where += ` AND EXISTS (
      SELECT 1 FROM post_tags ptf
      WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER($${params.length})
    )`;
  }

  params.push(limit, offset);
  const sql = `
    ${buildPostSelect('$1')}
    ${where}
    GROUP BY p.id, u.id
    ORDER BY p.created_at DESC
    LIMIT $${params.length - 1} OFFSET $${params.length}
  `;

  const { rows } = await query(sql, params);
  return rows;
}

async function countAll({ mode, authorId, viewerId = null, tag = null, connectionsOnly = false }) {
  const params = [viewerId];
  let where = `WHERE p.status = 'posted' AND p.community_id IS NULL
    AND ${privacyClause('$1')} AND ${notBlockedClause('$1')} AND ${notHiddenClause('$1')}`;

  if (connectionsOnly) {
    where += ` AND ${connectionsOnlyClause('$1')}`;
  }
  if (mode) {
    params.push(mode);
    where += ` AND p.mode = $${params.length}`;
  }
  if (authorId) {
    params.push(authorId);
    where += ` AND p.author_id = $${params.length}`;
  }
  if (tag) {
    params.push(tag);
    where += ` AND EXISTS (
      SELECT 1 FROM post_tags ptf
      WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER($${params.length})
    )`;
  }

  const { rows } = await query(`SELECT COUNT(*) FROM posts p ${where}`, params);
  return parseInt(rows[0].count, 10);
}

async function findById(id, viewerId = null) {
  const sql = `
    ${buildPostSelect('$2')}
    WHERE p.id = $1 AND p.status = 'posted'
      AND ${privacyClause('$2')} AND ${notBlockedClause('$2')}
    GROUP BY p.id, u.id
  `;
  const { rows } = await query(sql, [id, viewerId]);
  return rows[0] || null;
}

async function create({ authorId, content, mode, privacy = 'public', imageUrl = null, imageUrls = null, linkUrl = null, articleTitle = null, sharedPostId = null }) {
  const validPrivacy = ['public', 'friends', 'only_me'].includes(privacy)
    ? privacy : 'public';
  // Client cũ gửi image_url đơn lẻ → gói vào mảng; DB chỉ còn image_urls
  const urls = Array.isArray(imageUrls) && imageUrls.length > 0
    ? imageUrls
    : (imageUrl ? [imageUrl] : null);
  const { rows } = await query(
    `INSERT INTO posts (author_id, content, mode, privacy, image_urls, link_url, article_title, shared_post_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
     RETURNING id`,
    [authorId, content ?? '', mode, validPrivacy, urls, linkUrl, articleTitle, sharedPostId]
  );
  // Increment post_count on user
  await query(
    `UPDATE users SET post_count = post_count + 1 WHERE id = $1`,
    [authorId]
  );
  return findById(rows[0].id, authorId);
}

// Insert a community post; postType defaults to 'text' — backward compatible
async function createCommunityPost({ content, authorId, communityId, postType = 'text' }) {
  const { rows } = await query(
    `INSERT INTO posts (author_id, content, mode, privacy, community_id, post_type)
     VALUES ($1, $2, 'hobby', 'public', $3, $4)
     RETURNING id`,
    [authorId, content, communityId, postType]
  );
  return findById(rows[0].id, authorId);
}

// Posts belonging to a community — pinned post first, then newest first.
// Includes post_type, is_pinned, and inline poll/event data in a single query.
async function getPostsByCommunity(communityId, { limit = 20, offset = 0, requestingUserId = null } = {}) {
  const params = [communityId, limit, offset];

  let isLikedExpr  = 'false AS is_liked';
  let userRsvpExpr = 'NULL::VARCHAR';
  let userVoteExpr = 'NULL::TEXT';

  if (requestingUserId) {
    params.push(requestingUserId);
    const idx = params.length; // e.g. $4
    isLikedExpr  = `EXISTS(
      SELECT 1 FROM post_likes pl WHERE pl.post_id = p.id AND pl.user_id = $${idx}
    ) AS is_liked`;
    userRsvpExpr = `(SELECT er.status FROM event_rsvps er
                     WHERE er.event_id = ce.id AND er.user_id = $${idx})`;
    userVoteExpr = `(SELECT pv.poll_option_id::TEXT
                     FROM poll_votes pv
                     JOIN poll_options po2 ON po2.id = pv.poll_option_id
                     WHERE po2.post_id = p.id AND pv.user_id = $${idx})`;
  }

  const sql = `
    SELECT
      p.id, p.content, p.like_count, p.comment_count, p.created_at,
      p.post_type, p.is_pinned, p.pinned_at,
      ${isLikedExpr},
      json_build_object(
        'id',           u.id,
        'username',     u.username,
        'display_name', u.display_name,
        'avatar_color', u.avatar_color,
        'avatar_url',   u.avatar_url
      ) AS author,
      json_build_object(
        'id',         c.id,
        'name',       c.name,
        'icon_emoji', c.icon_emoji
      ) AS community,
      CASE WHEN p.post_type = 'event' THEN
        json_build_object(
          'id',         ce.id,
          'title',      ce.title,
          'location',   ce.location,
          'starts_at',  ce.starts_at,
          'ends_at',    ce.ends_at,
          'rsvp_count', ce.rsvp_count,
          'user_rsvp',  ${userRsvpExpr}
        )
      ELSE NULL END AS event_data,
      CASE WHEN p.post_type = 'poll' THEN
        json_build_object(
          'options', (
            SELECT json_agg(
              json_build_object(
                'id',         po.id,
                'text',       po.text,
                'vote_count', po.vote_count,
                'position',   po.position,
                'ends_at',    po.ends_at
              ) ORDER BY po.position
            )
            FROM poll_options po WHERE po.post_id = p.id
          ),
          'user_vote', ${userVoteExpr}
        )
      ELSE NULL END AS poll_data
    FROM posts p
    JOIN users u ON u.id = p.author_id
    LEFT JOIN communities c ON c.id = p.community_id
    LEFT JOIN community_events ce ON ce.post_id = p.id
    WHERE p.community_id = $1 AND p.status = 'posted'
    ORDER BY p.is_pinned DESC, p.created_at DESC
    LIMIT $2 OFFSET $3
  `;

  const { rows } = await query(sql, params);
  return rows;
}

// Lightweight fetch used by service layer for auth/type checks
async function findPostMeta(postId) {
  const { rows } = await query(
    `SELECT id, author_id, community_id, post_type FROM posts WHERE id = $1`,
    [postId]
  );
  return rows[0] || null;
}

// Hard-delete a post; returns { id, author_id, community_id } for counter cleanup
async function deletePost(postId) {
  const { rows } = await query(
    `DELETE FROM posts WHERE id = $1 RETURNING id, author_id, community_id`,
    [postId]
  );
  return rows[0] || null;
}

// Soft-delete: chỉ set status = 'deleted', không xóa row khỏi DB.
// Đồng thời trừ post_count trên users để số bài viết hiển thị đúng.
async function softDeletePost(postId) {
  const { rows } = await query(
    `UPDATE posts SET status = 'deleted', updated_at = NOW()
     WHERE id = $1
     RETURNING id, author_id`,
    [postId]
  );
  if (rows[0]) {
    await query(
      `UPDATE users SET post_count = GREATEST(post_count - 1, 0) WHERE id = $1`,
      [rows[0].author_id]
    );
  }
  return rows[0] || null;
}

// Cập nhật nội dung bài viết; trả về post đầy đủ sau khi update
async function updatePost(postId, { content, privacy, imageUrl, imageUrls, linkUrl, articleTitle }) {
  const validPrivacy = ['public', 'friends', 'only_me'].includes(privacy)
    ? privacy : null;
  // Client cũ gửi image_url đơn lẻ → gói vào mảng; DB chỉ còn image_urls
  const urls = Array.isArray(imageUrls) && imageUrls.length > 0
    ? imageUrls
    : (imageUrl ? [imageUrl] : null);

  const { rows } = await query(
    `UPDATE posts SET
       content       = COALESCE($2, content),
       privacy       = COALESCE($3, privacy),
       image_urls    = $4,
       link_url      = $5,
       article_title = $6,
       updated_at    = NOW()
     WHERE id = $1 AND status = 'posted'
     RETURNING id, author_id`,
    [postId, content ?? null, validPrivacy, urls, linkUrl ?? null, articleTitle ?? null]
  );
  if (!rows[0]) return null;
  return findById(rows[0].id, rows[0].author_id);
}

module.exports = {
  findAll, countAll, findById, create,
  createCommunityPost, getPostsByCommunity,
  findPostMeta, deletePost, softDeletePost, updatePost,
};
