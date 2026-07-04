const { query } = require('../config/db');

/** Insert a new user notification record. */
async function createNotification({ userId, type, postId, payload }) {
  const { rows } = await query(
    `INSERT INTO user_notifications (user_id, type, post_id, payload)
     VALUES ($1, $2, $3, $4)
     RETURNING *`,
    [userId, type, postId || null, JSON.stringify(payload)]
  );
  return rows[0];
}

/** Paginated list of notifications for a user, newest first. */
async function listForUser(userId, { limit = 30, offset = 0 } = {}) {
  const { rows } = await query(
    `SELECT id, type, post_id, payload, is_read, resolved_at, created_at
     FROM user_notifications
     WHERE user_id = $1
     ORDER BY created_at DESC
     LIMIT $2 OFFSET $3`,
    [userId, limit, offset]
  );
  return rows;
}

/** Mark a single notification as read (owner check). */
async function markRead(notificationId, userId) {
  const { rows } = await query(
    `UPDATE user_notifications
     SET is_read = TRUE
     WHERE id = $1 AND user_id = $2
     RETURNING *`,
    [notificationId, userId]
  );
  return rows[0] || null;
}

/** Resolve a notification — sets resolved_at and is_read. */
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

/** Mark ALL of a user's notifications as read. */
async function markAllRead(userId) {
  await query(
    `UPDATE user_notifications SET is_read = TRUE
     WHERE user_id = $1 AND is_read = FALSE`,
    [userId]
  );
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

/** Find a specific notification by id (for ownership check). */
async function findById(notificationId) {
  const { rows } = await query(
    `SELECT * FROM user_notifications WHERE id = $1`,
    [notificationId]
  );
  return rows[0] || null;
}

module.exports = { createNotification, listForUser, markRead, markAllRead, resolve, getUnreadCount, findById };
