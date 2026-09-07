const { query } = require('../config/db');

// Returns one community row; if requestingUserId given, also returns is_member,
// role, and the requester's own join_request_status ('pending' | 'approved' |
// 'rejected' | null) so the client can show a "pending" state without a
// separate call.
async function getCommunityById(id, requestingUserId = null) {
  const params = [id];
  const memberJoin = requestingUserId
    ? `LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = $2
       LEFT JOIN community_join_requests jr ON jr.community_id = c.id AND jr.user_id = $2`
    : '';
  const memberFields = requestingUserId
    ? `(cm.user_id IS NOT NULL) AS is_member, cm.role, jr.status AS join_request_status`
    : `false AS is_member, NULL::VARCHAR AS role, NULL::VARCHAR AS join_request_status`;

  if (requestingUserId) params.push(requestingUserId);

  const sql = `
    SELECT c.id, c.name, c.description, c.type, c.privacy,
           c.icon_emoji, c.cover_color, c.member_count, c.post_count,
           c.created_by, c.created_at,
           ${memberFields}
    FROM communities c
    ${memberJoin}
    WHERE c.id = $1
  `;

  const { rows } = await query(sql, params);
  return rows[0] || null;
}

// Number of admins in a community — used to block the last admin from leaving
// or being demoted (which would orphan the community).
async function countAdmins(communityId) {
  const { rows } = await query(
    `SELECT COUNT(*)::int AS n FROM community_members
     WHERE community_id = $1 AND role = 'admin'`,
    [communityId]
  );
  return rows[0].n;
}

// Insert a new community row (does NOT add member — service layer does that)
async function createCommunity({ name, description, type, privacy, iconEmoji, coverColor, createdBy }) {
  const { rows } = await query(
    `INSERT INTO communities (name, description, type, privacy, icon_emoji, cover_color, created_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     RETURNING *`,
    [name.trim(), description || null, type, privacy, iconEmoji, coverColor, createdBy]
  );
  return rows[0];
}

// Full-text search on name/description; only returns public communities.
// Supports optional tags filter and sort (members | newest | trending).
async function searchCommunities({
  searchQuery = '', type = null, tags = [], sort = 'members',
  limit = 20, offset = 0, requestingUserId = null,
}) {
  const params = [`%${searchQuery}%`];

  // Member join (build first to keep index stable)
  let memberJoin  = '';
  let memberField = 'false AS is_member, NULL::VARCHAR AS role,';
  if (requestingUserId) {
    params.push(requestingUserId);
    memberJoin  = `LEFT JOIN community_members cm ON cm.community_id = c.id AND cm.user_id = $${params.length}`;
    memberField = `(cm.user_id IS NOT NULL) AS is_member, cm.role,`;
  }

  // Type filter
  let typeFilter = '';
  if (type) {
    params.push(type);
    typeFilter = `AND c.type = $${params.length}`;
  }

  // Tags filter — communities that have ANY of the requested tags
  let tagsFilter = '';
  if (tags && tags.length > 0) {
    const tagPlaceholders = tags.map(t => { params.push(t); return `$${params.length}`; });
    tagsFilter = `AND EXISTS (
      SELECT 1 FROM community_tags ct
      WHERE ct.community_id = c.id AND ct.tag IN (${tagPlaceholders.join(', ')})
    )`;
  }

  // Sort order
  let orderBy = 'ORDER BY c.member_count DESC, c.created_at DESC';
  if (sort === 'newest')   orderBy = 'ORDER BY c.created_at DESC';
  if (sort === 'trending') orderBy = 'ORDER BY COALESCE(tr.score, 0) DESC, c.member_count DESC';

  params.push(limit, offset);
  const limitIdx  = params.length - 1;
  const offsetIdx = params.length;

  const sql = `
    SELECT c.id, c.name, c.description, c.type, c.privacy,
           c.icon_emoji, c.cover_color, c.member_count, c.post_count, c.created_at,
           ${memberField}
           COALESCE(tr.score, 0) AS trending_score
    FROM communities c
    ${memberJoin}
    LEFT JOIN community_trending tr ON tr.community_id = c.id
    WHERE (c.name ILIKE $1 OR c.description ILIKE $1)
      AND c.privacy = 'public'
      ${typeFilter}
      ${tagsFilter}
    ${orderBy}
    LIMIT $${limitIdx} OFFSET $${offsetIdx}
  `;

  const { rows } = await query(sql, params);
  return rows;
}

// All communities the user has joined
async function getCommunitiesByUser(userId) {
  const { rows } = await query(
    `SELECT c.id, c.name, c.description, c.type, c.privacy,
            c.icon_emoji, c.cover_color, c.member_count, c.post_count, c.created_at,
            cm.role
     FROM communities c
     JOIN community_members cm ON cm.community_id = c.id
     WHERE cm.user_id = $1
     ORDER BY cm.joined_at DESC`,
    [userId]
  );
  return rows;
}

// Add a user to community_members
async function joinCommunity(communityId, userId, role = 'member') {
  const { rows } = await query(
    `INSERT INTO community_members (community_id, user_id, role)
     VALUES ($1, $2, $3)
     RETURNING *`,
    [communityId, userId, role]
  );
  return rows[0];
}

// Remove a user from community_members
async function leaveCommunity(communityId, userId) {
  const { rows } = await query(
    `DELETE FROM community_members
     WHERE community_id = $1 AND user_id = $2
     RETURNING *`,
    [communityId, userId]
  );
  return rows[0] || null;
}

// Returns membership row { role } or null if not a member
async function isMember(communityId, userId) {
  const { rows } = await query(
    `SELECT role FROM community_members WHERE community_id = $1 AND user_id = $2`,
    [communityId, userId]
  );
  return rows[0] || null;
}

// Paginated member list, admins first then by join date
async function getCommunityMembers(communityId, { limit = 20, offset = 0 } = {}) {
  const { rows } = await query(
    `SELECT u.id, u.username, u.display_name, u.avatar_color, u.job_title, u.company,
            cm.role, cm.joined_at
     FROM community_members cm
     JOIN users u ON u.id = cm.user_id
     WHERE cm.community_id = $1
     ORDER BY
       CASE cm.role WHEN 'admin' THEN 0 WHEN 'moderator' THEN 1 ELSE 2 END,
       cm.joined_at ASC
     LIMIT $2 OFFSET $3`,
    [communityId, limit, offset]
  );
  return rows;
}

// Adjust member_count by delta (+1 on join, -1 on leave)
async function incrementMemberCount(communityId, delta) {
  await query(
    `UPDATE communities SET member_count = member_count + $2 WHERE id = $1`,
    [communityId, delta]
  );
}

// Adjust post_count by delta (+1 on create, -1 on delete)
async function incrementPostCount(communityId, delta) {
  await query(
    `UPDATE communities SET post_count = post_count + $2 WHERE id = $1`,
    [communityId, delta]
  );
}

// ── Phase 3: Ban check ────────────────────────────────────────────────────────

// Returns true if the user is permanently banned from the community
async function isBanned(communityId, userId) {
  const { rows } = await query(
    `SELECT 1 FROM community_bans WHERE community_id = $1 AND user_id = $2`,
    [communityId, userId]
  );
  return rows.length > 0;
}

// ── Phase 2 additions ─────────────────────────────────────────────────────────

// Pin a post in a community; unpins any previously pinned post first
async function pinPost(postId, communityId, adminId) {
  await query(
    `UPDATE posts
     SET is_pinned = FALSE, pinned_at = NULL, pinned_by = NULL
     WHERE community_id = $1 AND is_pinned = TRUE`,
    [communityId]
  );
  const { rows } = await query(
    `UPDATE posts
     SET is_pinned = TRUE, pinned_at = NOW(), pinned_by = $2
     WHERE id = $1 AND community_id = $3
     RETURNING id`,
    [postId, adminId, communityId]
  );
  return rows[0] || null;
}

// Unpin a specific post
async function unpinPost(postId, communityId) {
  const { rows } = await query(
    `UPDATE posts
     SET is_pinned = FALSE, pinned_at = NULL, pinned_by = NULL
     WHERE id = $1 AND community_id = $2
     RETURNING id`,
    [postId, communityId]
  );
  return rows[0] || null;
}

// Return the ID of the currently pinned post, or null
async function getPinnedPost(communityId) {
  const { rows } = await query(
    `SELECT id FROM posts WHERE community_id = $1 AND is_pinned = TRUE LIMIT 1`,
    [communityId]
  );
  return rows[0] || null;
}

// Remove a member from a community (kick)
async function kickMember(communityId, targetUserId) {
  const { rows } = await query(
    `DELETE FROM community_members
     WHERE community_id = $1 AND user_id = $2
     RETURNING *`,
    [communityId, targetUserId]
  );
  return rows[0] || null;
}

// Update a community member's role
async function updateMemberRole(communityId, targetUserId, newRole) {
  const { rows } = await query(
    `UPDATE community_members
     SET role = $3
     WHERE community_id = $1 AND user_id = $2
     RETURNING *`,
    [communityId, targetUserId, newRole]
  );
  return rows[0] || null;
}

module.exports = {
  getCommunityById,
  createCommunity,
  searchCommunities,
  getCommunitiesByUser,
  joinCommunity,
  leaveCommunity,
  isMember,
  getCommunityMembers,
  incrementMemberCount,
  incrementPostCount,
  // Phase 2
  pinPost,
  unpinPost,
  getPinnedPost,
  kickMember,
  updateMemberRole,
  countAdmins,
  // Phase 3
  isBanned,
};
