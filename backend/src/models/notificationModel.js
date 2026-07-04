const { query } = require('../config/db');

// Create a single notification record
async function createNotification({ communityId, userId, type, refId = null }) {
  const { rows } = await query(
    `INSERT INTO community_notifications (community_id, user_id, type, ref_id)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [communityId, userId, type, refId]
  );
  return rows[0];
}

// Efficiently bulk-create notifications for all community members in a single query,
// excluding the user who triggered the action (e.g. the post author).
async function createBulkNotifications(communityId, type, refId, excludeUserId) {
  await query(
    `INSERT INTO community_notifications (community_id, user_id, type, ref_id)
     SELECT $1, cm.user_id, $2, $3
     FROM community_members cm
     WHERE cm.community_id = $1
       AND cm.user_id != $4`,
    [communityId, type, refId, excludeUserId]
  );
}

// Paginated notification list for a user, newest first, with community name
async function getNotificationsForUser(userId, { limit = 20, offset = 0 } = {}) {
  const { rows } = await query(
    `SELECT cn.id, cn.community_id, cn.type, cn.ref_id, cn.is_read, cn.created_at,
            c.name AS community_name
     FROM community_notifications cn
     JOIN communities c ON c.id = cn.community_id
     WHERE cn.user_id = $1
     ORDER BY cn.created_at DESC
     LIMIT $2 OFFSET $3`,
    [userId, limit, offset]
  );
  return rows;
}

// Mark a single notification as read; only the owner may do this
async function markAsRead(notificationId, userId) {
  const { rows } = await query(
    `UPDATE community_notifications
     SET is_read = TRUE
     WHERE id = $1 AND user_id = $2
     RETURNING *`,
    [notificationId, userId]
  );
  return rows[0] || null;
}

// Mark all of a user's notifications as read
async function markAllAsRead(userId) {
  await query(
    `UPDATE community_notifications SET is_read = TRUE WHERE user_id = $1`,
    [userId]
  );
}

// Return count of unread notifications for a user
async function getUnreadCount(userId) {
  const { rows } = await query(
    `SELECT COUNT(*) FROM community_notifications
     WHERE user_id = $1 AND is_read = FALSE`,
    [userId]
  );
  return parseInt(rows[0].count, 10);
}

module.exports = {
  createNotification,
  createBulkNotifications,
  getNotificationsForUser,
  markAsRead,
  markAllAsRead,
  getUnreadCount,
};
