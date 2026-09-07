const { query } = require('../config/db');
const { personaExpr } = require('../utils/personaSql');

// Shared SELECT for post rows. `viewerRef` is a SQL placeholder (e.g. '$1') holding
// the viewer's UUID (or NULL) — always parameterized, never string-interpolated.
// Author identity resolves according to the POST'S OWN MODE persona (p.mode/sp.mode) —
// a hobby post shows the hobby display name, a work post shows the work display name.
const buildPostSelect = (viewerRef) => `
  SELECT
    p.id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.article_title, p.link_url,
    p.like_count, p.comment_count, p.share_count, p.created_at,
    p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id,
    EXISTS(
      SELECT 1 FROM post_likes pl
      WHERE pl.post_id = p.id AND pl.user_id = ${viewerRef}::uuid
    ) AS is_liked,
    EXISTS(
      SELECT 1 FROM saved_posts sp2
      WHERE sp2.post_id = p.id AND sp2.user_id = ${viewerRef}::uuid
    ) AS is_saved,
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
    -- Visibility-aware: user-typed hashtags always show; AI-extracted tags
    -- only show when the author opted in via posts.show_ai_tags at creation
    -- time. A hidden AI tag never reaches the API response at all.
    COALESCE(json_agg(DISTINCT pt.tag) FILTER (
      WHERE pt.tag IS NOT NULL AND (pt.source = 'user' OR p.show_ai_tags)
    ), '[]') AS tags,
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

// Post view permission: public, your own post, or 'friends' when both sides have
// an accepted connection. 'only_me' is visible to the author only.
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

// View permission for posts BELONGING to a community: Feed posts (community_id IS
// NULL) always pass, untouched by this logic. A community post is only viewable
// when that community is public, the viewer is a member, or the viewer is the
// post's own author. Needs a separate clause because community posts are always
// created with privacy='public' (privacyClause alone isn't enough to block a
// private community) — actual visibility is governed by the community's privacy +
// membership, not by posts.privacy.
const communityVisibilityClause = (viewerRef) => `
  (
    p.community_id IS NULL
    OR p.author_id = ${viewerRef}::uuid
    OR EXISTS (
      SELECT 1 FROM communities co
      WHERE co.id = p.community_id AND co.privacy = 'public'
    )
    OR EXISTS (
      SELECT 1 FROM community_members cm
      WHERE cm.community_id = p.community_id AND cm.user_id = ${viewerRef}::uuid
    )
  )
`;

// Excludes posts from users who are blocked/blocking (both directions) relative to the viewer
const notBlockedClause = (viewerRef) => `
  NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE (ub.blocker_id = ${viewerRef}::uuid AND ub.blocked_id = p.author_id)
       OR (ub.blocker_id = p.author_id AND ub.blocked_id = ${viewerRef}::uuid)
  )
`;

// Excludes posts the viewer has tapped "Hide post" on (only applied to list-style
// queries; findById leaves it unfiltered so a share embed / notification can still open the post)
const notHiddenClause = (viewerRef) => `
  NOT EXISTS (
    SELECT 1 FROM hidden_posts hp
    WHERE hp.user_id = ${viewerRef}::uuid AND hp.post_id = p.id
  )
`;

// Only show posts by yourself + by people with an accepted connection
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
        AND (ptf.source = 'user' OR p.show_ai_tags)
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
        AND (ptf.source = 'user' OR p.show_ai_tags)
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
      AND ${communityVisibilityClause('$2')}
    GROUP BY p.id, u.id
  `;
  const { rows } = await query(sql, [id, viewerId]);
  return rows[0] || null;
}

// Sanitize user-typed hashtags before insert: trim, drop empties, cap to the
// post_tags.tag column's 100-char limit, dedupe case-insensitively (first
// occurrence's casing wins) — mirrors the UNIQUE(post_id, tag) constraint's
// exact-match semantics while still preventing "Coffee" + "coffee" both
// landing on the same post as visually-duplicate chips.
const MAX_HASHTAGS_PER_POST = 10;

function sanitizeHashtags(hashtags) {
  if (!Array.isArray(hashtags)) return [];
  const seen = new Set();
  const out = [];
  for (const raw of hashtags) {
    if (out.length >= MAX_HASHTAGS_PER_POST) break;
    if (typeof raw !== 'string') continue;
    // Strip ALL whitespace, not just leading/trailing — a hashtag is a single
    // token by definition, and the client only guards this client-side
    // (space commits/ends a token), so the server must not trust that.
    const trimmed = raw.replace(/\s+/g, '').slice(0, 100);
    if (!trimmed) continue;
    const key = trimmed.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(trimmed);
  }
  return out;
}

async function create({ authorId, content, mode, privacy = 'public', imageUrl = null, imageUrls = null, linkUrl = null, articleTitle = null, sharedPostId = null, hashtags = [], showAiTags = false }) {
  const validPrivacy = ['public', 'friends', 'only_me'].includes(privacy)
    ? privacy : 'public';
  // Older clients send a single image_url → wrap it into an array; the DB only keeps image_urls
  const urls = Array.isArray(imageUrls) && imageUrls.length > 0
    ? imageUrls
    : (imageUrl ? [imageUrl] : null);
  const { rows } = await query(
    `INSERT INTO posts (author_id, content, mode, privacy, image_urls, link_url, article_title, shared_post_id, show_ai_tags)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
     RETURNING id`,
    [authorId, content ?? '', mode, validPrivacy, urls, linkUrl, articleTitle, sharedPostId, !!showAiTags]
  );
  // Increment post_count on user
  await query(
    `UPDATE users SET post_count = post_count + 1 WHERE id = $1`,
    [authorId]
  );

  // User-typed hashtags must be reliably saved (unlike AI tags, which are
  // best-effort) — insert synchronously, awaited, as part of creation.
  const cleanTags = sanitizeHashtags(hashtags);
  if (cleanTags.length) {
    await query(
      `INSERT INTO post_tags (post_id, tag, source)
       SELECT $1, UNNEST($2::text[]), 'user'
       ON CONFLICT (post_id, tag) DO NOTHING`,
      [rows[0].id, cleanTags]
    );
  }

  return findById(rows[0].id, authorId);
}

// Insert a community post; postType defaults to 'text' — backward compatible.
// image_urls/link_url/article_title accepted for parity with Feed's create()
// (same shape, cap-10 filtering already applied by the caller — see
// utils/postInput.js's normalizeImageUrls). mode is derived from the
// community's own type (work → work, anything else → hobby) instead of being
// hardcoded, so persona resolution matches the community's context; falls
// back to 'hobby' if communityId doesn't resolve (defensive — every real
// caller always passes a valid community id).
// `mode`/`privacy` are optional overrides — when omitted (the community
// route's existing behavior), mode still derives from the community's type
// and privacy still defaults to 'public', unchanged. Feed callers (no
// communityId) pass these explicitly so a Feed poll/event honors the
// composer's actual mode/privacy choice instead of silently falling back.
async function createCommunityPost({
  content, authorId, communityId, postType = 'text',
  imageUrls = null, linkUrl = null, articleTitle = null,
  hashtags = [], showAiTags = false, mode = null, privacy = null,
}) {
  const { rows } = await query(
    `INSERT INTO posts (author_id, content, mode, privacy, community_id, post_type, image_urls, link_url, article_title, show_ai_tags)
     VALUES (
       $1, $2,
       COALESCE($9, (SELECT CASE WHEN type = 'work' THEN 'work' ELSE 'hobby' END
                 FROM communities WHERE id = $3), 'hobby'),
       COALESCE($10, 'public'), $3, $4, $5, $6, $7, $8
     )
     RETURNING id`,
    [authorId, content ?? '', communityId, postType, imageUrls, linkUrl, articleTitle, !!showAiTags, mode, privacy]
  );

  // User-typed hashtags must be reliably saved (unlike AI tags, which are
  // best-effort) — insert synchronously, awaited, as part of creation.
  // Mirrors Feed's create() exactly (same sanitize helper, same conflict rule).
  const cleanTags = sanitizeHashtags(hashtags);
  if (cleanTags.length) {
    await query(
      `INSERT INTO post_tags (post_id, tag, source)
       SELECT $1, UNNEST($2::text[]), 'user'
       ON CONFLICT (post_id, tag) DO NOTHING`,
      [rows[0].id, cleanTags]
    );
  }

  return findById(rows[0].id, authorId);
}

// Posts belonging to a community — pinned post first, then newest first.
// Built on the shared buildPostSelect fragment (same one Feed uses) so
// community posts automatically get every column Feed posts get (images,
// link preview, tags, persona-aware author) with no column drift going
// forward. The community's own extras (embedded `community` object) that
// buildPostSelect doesn't carry are merged in via an outer wrapper query —
// post_type/is_pinned/pinned_at/event_data/poll_data already come from
// buildPostSelect itself, so nothing else needs preserving separately.
async function getPostsByCommunity(communityId, { limit = 20, offset = 0, requestingUserId = null, tag = null } = {}) {
  const params = [requestingUserId, communityId];
  // Same visibility-aware EXISTS subquery as findAll/countAll's `tag` filter —
  // a hidden AI tag can never surface a community post via ?tag=.
  let tagClause = '';
  if (tag) {
    params.push(tag);
    tagClause = ` AND EXISTS (
      SELECT 1 FROM post_tags ptf
      WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER($${params.length})
        AND (ptf.source = 'user' OR p.show_ai_tags)
    )`;
  }
  params.push(limit, offset);
  const sql = `
    SELECT sub.*,
      (SELECT json_build_object('id', co.id, 'name', co.name, 'icon_emoji', co.icon_emoji)
       FROM communities co WHERE co.id = $2) AS community
    FROM (
      ${buildPostSelect('$1')}
      WHERE p.community_id = $2 AND p.status = 'posted'${tagClause}
      GROUP BY p.id, u.id
    ) sub
    ORDER BY sub.is_pinned DESC, sub.created_at DESC
    LIMIT $${params.length - 1} OFFSET $${params.length}
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

// Soft-delete: only sets status = 'deleted', doesn't remove the row from the DB.
// deleted_at records the deletion time — used to sort "Recently Deleted" by recency
// and as the reference point for the purge job (auto hard-delete after 30 days, see postPurgeJob.js).
// Also decrements post_count on users so the displayed post count stays accurate.
// Returns community_id (or null) so a caller can symmetrically adjust
// communities.post_count — the caller owns that decrement, this function does not
// (postService.deletePost already does it via findPostMeta; doing it here too
// would double-count).
async function softDeletePost(postId) {
  const { rows } = await query(
    `UPDATE posts SET status = 'deleted', deleted_at = NOW(), updated_at = NOW()
     WHERE id = $1
     RETURNING id, author_id, community_id`,
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

// Restore a soft-deleted post — author-only (does NOT extend to community
// staff, unlike delete's own authorization; a staff member can remove content
// but recovering your own deleted post is a personal action, kept simple per
// plan). Only succeeds if the post is currently 'deleted'; flips status back
// to 'posted' and clears deleted_at. Re-increments post_count (undoes
// softDeletePost's decrement) and, if the post belongs to a community,
// returns community_id so the caller can symmetrically re-increment
// communities.post_count too (mirrors deletePost's own decrement there).
// Returns the full post shape via findById (same embed every other
// post-returning endpoint uses) or null if nothing matched (wrong owner,
// post doesn't exist, or post isn't currently deleted).
async function restorePost(postId, requesterId) {
  const { rows } = await query(
    `UPDATE posts SET status = 'posted', deleted_at = NULL, updated_at = NOW()
     WHERE id = $1 AND author_id = $2 AND status = 'deleted'
     RETURNING id, author_id, community_id`,
    [postId, requesterId]
  );
  const restored = rows[0];
  if (!restored) return null;

  await query(
    `UPDATE users SET post_count = post_count + 1 WHERE id = $1`,
    [restored.author_id]
  );

  return findById(restored.id, requesterId);
}

// The current user's own soft-deleted posts, newest deleted_at first — built
// on the shared buildPostSelect fragment so a "Recently Deleted" list gets
// the exact same shape (tags, author, images, etc.) as every other post list.
async function listDeletedPosts(userId, { limit = 20, offset = 0 } = {}) {
  const params = [userId, limit, offset];
  const sql = `
    ${buildPostSelect('$1')}
    WHERE p.author_id = $1 AND p.status = 'deleted'
    GROUP BY p.id, u.id
    ORDER BY MAX(p.deleted_at) DESC
    LIMIT $2 OFFSET $3
  `;
  const { rows } = await query(sql, params);
  return rows;
}

// The current user's saved (bookmarked) posts, newest saved first — built on
// the shared buildPostSelect fragment for the same-shape guarantee as every
// other post list. Unlike listDeletedPosts (author-only, no privacy filter
// needed), this MUST reuse the same privacyClause/notBlockedClause helpers
// findAll applies — a saved post whose author later restricted privacy or
// blocked the viewer must not leak into this list.
async function listSavedPosts(userId, { limit = 20, offset = 0 } = {}) {
  const params = [userId, limit, offset];
  const sql = `
    ${buildPostSelect('$1')}
    JOIN saved_posts sap ON sap.post_id = p.id AND sap.user_id = $1
    WHERE p.status = 'posted' AND ${privacyClause('$1')} AND ${notBlockedClause('$1')}
    GROUP BY p.id, u.id, sap.created_at
    ORDER BY sap.created_at DESC
    LIMIT $2 OFFSET $3
  `;
  const { rows } = await query(sql, params);
  return rows;
}

// Update a post's content; returns the full post after the update.
// `contentProvided` distinguishes "content field omitted from the request" (keep
// the existing caption — the CASE below falls through to `content`) from
// "content field explicitly sent, possibly as an empty string" (write it as-is,
// including clearing the caption to '') — a plain COALESCE($2, content) used to
// collapse both cases together because an intentionally-cleared caption trims to
// '' which COALESCE treats the same as "not provided", so a cleared caption was
// silently reverted to the old one. Returns:
//   - the updated post row (success)
//   - null if the post doesn't exist / isn't 'posted'
//   - the string 'empty' if applying this edit would leave the post with no
//     content, no images, and no link — same content_or_media invariant enforced
//     at creation time (see createPost's `hasContent`/`hasLink`/imageUrls check).
async function updatePost(postId, { content, contentProvided = false, privacy, imageUrl, imageUrls, linkUrl, articleTitle }) {
  const validPrivacy = ['public', 'friends', 'only_me'].includes(privacy)
    ? privacy : null;
  // Older clients send a single image_url → wrap it into an array; the DB only keeps image_urls
  const urls = Array.isArray(imageUrls) && imageUrls.length > 0
    ? imageUrls
    : (imageUrl ? [imageUrl] : null);

  // image_urls/link_url are always fully overwritten by the caller (no
  // "omitted" case for them, unlike content) — only content needs the row's
  // current value to evaluate the post-update invariant below.
  const { rows: existingRows } = await query(
    `SELECT content FROM posts WHERE id = $1 AND status = 'posted'`,
    [postId]
  );
  if (!existingRows[0]) return null;

  const finalContent = contentProvided ? content : existingRows[0].content;
  const hasContent = !!(finalContent && finalContent.trim());
  const hasImages  = Array.isArray(urls) && urls.length > 0;
  const hasLink    = !!linkUrl;
  if (!hasContent && !hasImages && !hasLink) {
    return 'empty';
  }

  const { rows } = await query(
    `UPDATE posts SET
       content       = CASE WHEN $7 THEN $2 ELSE content END,
       privacy       = COALESCE($3, privacy),
       image_urls    = $4,
       link_url      = $5,
       article_title = $6,
       updated_at    = NOW()
     WHERE id = $1 AND status = 'posted'
     RETURNING id, author_id`,
    [postId, contentProvided ? content : null, validPrivacy, urls, linkUrl ?? null, articleTitle ?? null, contentProvided]
  );
  if (!rows[0]) return null;
  return findById(rows[0].id, rows[0].author_id);
}

module.exports = {
  findAll, countAll, findById, create,
  createCommunityPost, getPostsByCommunity,
  findPostMeta, softDeletePost, updatePost,
  restorePost, listDeletedPosts, listSavedPosts,
  sanitizeHashtags,
};
