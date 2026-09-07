/**
 * userNotificationModel.js — every query against the unified notification
 * table. Since migration 026 this is the ONLY notification table: community
 * notifications were folded in here (see 026_unify_notifications.sql).
 */

const { query } = require('../config/db');

// Columns every read returns. community_name comes from a LEFT JOIN rather
// than the payload snapshot so a renamed community doesn't leave a stale name
// sitting in every member's inbox.
const SELECT_COLUMNS = `
  n.id, n.user_id, n.type, n.actor_id, n.post_id, n.community_id,
  n.conversation_id, n.entity_type, n.entity_id,
  COALESCE(n.group_key, n.type || ':' || n.id::text) AS group_key,
  n.payload, n.collapse_count, n.is_read, n.resolved_at,
  n.created_at, n.updated_at,
  c.name AS community_name`;

/** Insert a single notification. */
async function createNotification({
  userId, type, actorId = null, postId = null, communityId = null,
  conversationId = null, entityType = null, entityId = null,
  groupKey = null, payload = {},
}) {
  const { rows } = await query(
    `INSERT INTO user_notifications
       (user_id, type, actor_id, post_id, community_id, conversation_id,
        entity_type, entity_id, group_key, payload)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     RETURNING *`,
    [userId, type, actorId, postId, communityId, conversationId,
     entityType, entityId, groupKey, JSON.stringify(payload)]
  );
  return rows[0];
}

/**
 * Fan out one notification to every member of a community.
 *
 * `roles` optionally restricts delivery to e.g. ['admin', 'moderator'].
 * Doing that filter in SQL replaces the previous approach of fetching
 * getCommunityMembers({ limit: 500 }) and filtering in JS, which silently
 * skipped staff in communities larger than 500 members.
 */
async function createBulkForCommunity({
  communityId, type, actorId = null, excludeUserId = null, postId = null,
  entityType = null, entityId = null, groupKey = null, payload = {},
  roles = null,
}) {
  const { rows } = await query(
    `INSERT INTO user_notifications
       (user_id, type, actor_id, community_id, post_id,
        entity_type, entity_id, group_key, payload)
     SELECT cm.user_id, $2, $3, $1, $4, $5, $6, $7, $8::jsonb
     FROM community_members cm
     WHERE cm.community_id = $1
       AND ($9::uuid IS NULL OR cm.user_id <> $9)
       AND ($10::text[] IS NULL OR cm.role = ANY($10))
     RETURNING *`,
    [communityId, type, actorId, postId, entityType, entityId, groupKey,
     JSON.stringify(payload), excludeUserId, roles]
  );
  return rows;
}

/** Fan out one notification to an explicit list of recipients. */
async function createBulkForUsers({
  userIds, type, actorId = null, postId = null, communityId = null,
  conversationId = null, entityType = null, entityId = null,
  groupKey = null, payload = {},
}) {
  if (!userIds?.length) return [];
  const { rows } = await query(
    `INSERT INTO user_notifications
       (user_id, type, actor_id, post_id, community_id, conversation_id,
        entity_type, entity_id, group_key, payload)
     SELECT uid, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb
     FROM UNNEST($1::uuid[]) AS uid
     RETURNING *`,
    [userIds, type, actorId, postId, communityId, conversationId,
     entityType, entityId, groupKey, JSON.stringify(payload)]
  );
  return rows;
}

/**
 * Chat collapse — at most ONE unread 'message' row per (recipient,
 * conversation), bumped instead of duplicated.
 *
 * The sender is excluded and muted participants are skipped in the same
 * statement, so mute costs nothing extra and behaves identically for 1:1 and
 * group conversations. ON CONFLICT infers uq_user_notifs_message_conv via the
 * matching partial predicate.
 *
 * collapse_count resets to 1 when the previous row had been read, so the
 * number always means "messages since you last looked".
 */
async function upsertMessageNotification({
  conversationId, senderId, groupKey, payload = {},
}) {
  const { rows } = await query(
    `INSERT INTO user_notifications
       (user_id, type, actor_id, conversation_id, entity_type, entity_id,
        group_key, payload)
     SELECT cp.user_id, 'message', $2, $1, 'conversation', $1, $3, $4::jsonb
     FROM conversation_participants cp
     WHERE cp.conversation_id = $1
       AND cp.user_id <> $2
       AND (cp.muted_until IS NULL OR cp.muted_until <= NOW())
     ON CONFLICT (user_id, conversation_id) WHERE type = 'message'
     DO UPDATE SET
       collapse_count = CASE WHEN user_notifications.is_read
                             THEN 1
                             ELSE user_notifications.collapse_count + 1 END,
       is_read    = FALSE,
       actor_id   = EXCLUDED.actor_id,
       payload    = EXCLUDED.payload,
       updated_at = NOW()
     RETURNING *`,
    [conversationId, senderId, groupKey, JSON.stringify(payload)]
  );
  return rows;
}

/**
 * One page of notifications, newest first.
 *
 * Uses a keyset cursor on (updated_at, id) rather than OFFSET: a collapsed
 * chat row bumping to the top mid-scroll would make OFFSET paging duplicate or
 * skip rows. `offset` is still honoured when no cursor is supplied so the
 * older client keeps working.
 *
 * Returns one extra row beyond `limit` so the caller can report hasMore
 * without a second COUNT.
 */
async function listForUser(userId, {
  limit = 30, offset = 0, unreadOnly = false, types = null,
  cursorUpdatedAt = null, cursorId = null,
} = {}) {
  const { rows } = await query(
    `SELECT ${SELECT_COLUMNS}
     FROM user_notifications n
     LEFT JOIN communities c ON c.id = n.community_id
     WHERE n.user_id = $1
       AND ($2::boolean IS FALSE OR n.is_read = FALSE)
       AND ($3::text[] IS NULL OR n.type = ANY($3))
       AND ($4::timestamptz IS NULL OR (n.updated_at, n.id) < ($4, $5))
     ORDER BY n.updated_at DESC, n.id DESC
     LIMIT $6 OFFSET $7`,
    [userId, unreadOnly, types, cursorUpdatedAt, cursorId, limit + 1,
     cursorUpdatedAt ? 0 : offset]
  );

  const hasMore = rows.length > limit;
  return { rows: hasMore ? rows.slice(0, limit) : rows, hasMore };
}

/** A single notification with the same shape the list returns. */
async function findForUser(notificationId, userId) {
  const { rows } = await query(
    `SELECT ${SELECT_COLUMNS}
     FROM user_notifications n
     LEFT JOIN communities c ON c.id = n.community_id
     WHERE n.id = $1 AND n.user_id = $2`,
    [notificationId, userId]
  );
  return rows[0] || null;
}

/** Mark one notification read or unread (owner-scoped). */
async function setRead(notificationId, userId, isRead) {
  const { rows } = await query(
    `UPDATE user_notifications
     SET is_read = $3
     WHERE id = $1 AND user_id = $2
     RETURNING *`,
    [notificationId, userId, isRead]
  );
  return rows[0] || null;
}

/** Mark a single notification as read (owner check). */
async function markRead(notificationId, userId) {
  return setRead(notificationId, userId, true);
}

/** Resolve a notification — sets resolved_at and is_read. Used by mode_mismatch. */
async function resolve(notificationId, userId) {
  const { rows } = await query(
    `UPDATE user_notifications
     SET is_read = TRUE, resolved_at = NOW()
     WHERE id = $1 AND user_id = $2
     RETURNING *`,
    [notificationId, userId]
  );
  return rows[0] || null;
}

/** Mark all of a user's unread notifications read, optionally scoped to a category. */
async function markAllRead(userId, { types = null } = {}) {
  const { rows } = await query(
    `UPDATE user_notifications
     SET is_read = TRUE
     WHERE user_id = $1 AND is_read = FALSE
       AND ($2::text[] IS NULL OR type = ANY($2))
     RETURNING id`,
    [userId, types]
  );
  return rows.map((r) => r.id);
}

/** Permanently remove one notification (owner-scoped). */
async function deleteForUser(notificationId, userId) {
  const { rowCount } = await query(
    `DELETE FROM user_notifications WHERE id = $1 AND user_id = $2`,
    [notificationId, userId]
  );
  return rowCount > 0;
}

/**
 * Clear a conversation's inbox row when the user opens the chat, so the
 * unified badge can never disagree with the chat screen. Marked read rather
 * than deleted so the All filter keeps the history.
 */
async function markConversationRead(conversationId, userId) {
  const { rows } = await query(
    `UPDATE user_notifications
     SET is_read = TRUE, collapse_count = 1
     WHERE user_id = $2 AND conversation_id = $1
       AND type = 'message' AND is_read = FALSE
     RETURNING id`,
    [conversationId, userId]
  );
  return rows.map((r) => r.id);
}

/** Total unread plus a per-category breakdown, in one pass. */
async function getUnreadCounts(userId) {
  const { rows } = await query(
    `SELECT type, COUNT(*)::int AS count
     FROM user_notifications
     WHERE user_id = $1 AND is_read = FALSE
     GROUP BY type`,
    [userId]
  );
  return rows;
}

/** Count unread notifications for a user. */
async function getUnreadCount(userId) {
  const { rows } = await query(
    `SELECT COUNT(*) FROM user_notifications
     WHERE user_id = $1 AND is_read = FALSE`,
    [userId]
  );
  return parseInt(rows[0].count, 10);
}

/**
 * Is there already an *unread and recent* notification with this group key
 * from this actor? Used to avoid spamming when someone likes / unlikes /
 * re-likes. Bounded two ways — unread and a time window — because the previous
 * version scanned all history, so a single like a year ago permanently
 * suppressed every future like notification from that person.
 */
async function hasPendingDuplicate({ userId, groupKey, actorId, withinHours = 24 }) {
  const { rows } = await query(
    `SELECT 1 FROM user_notifications
     WHERE user_id = $1
       AND group_key = $2
       AND actor_id IS NOT DISTINCT FROM $3
       AND is_read = FALSE
       AND created_at > NOW() - ($4 || ' hours')::interval
     LIMIT 1`,
    [userId, groupKey, actorId, String(withinHours)]
  );
  return rows.length > 0;
}

/** Find a specific notification by id (for ownership check). */
async function findById(notificationId) {
  const { rows } = await query(
    `SELECT * FROM user_notifications WHERE id = $1`,
    [notificationId]
  );
  return rows[0] || null;
}

module.exports = {
  createNotification,
  createBulkForCommunity,
  createBulkForUsers,
  upsertMessageNotification,
  listForUser,
  findForUser,
  setRead,
  markRead,
  markAllRead,
  resolve,
  deleteForUser,
  markConversationRead,
  getUnreadCounts,
  getUnreadCount,
  hasPendingDuplicate,
  findById,
};
