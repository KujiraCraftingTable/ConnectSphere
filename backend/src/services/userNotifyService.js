/**
 * userNotifyService.js — tạo user notification trong DB rồi push realtime
 * qua Socket.IO tới room `user:<id>`. Lỗi notification không được làm fail
 * request chính nên mọi lỗi chỉ log warning.
 */

const userNotifModel = require('../models/userNotificationModel');
const { query }      = require('../config/db');
const { emitToUser } = require('../utils/realtime');
const logger         = require('../utils/logger');

// Tạo notification + emit socket event 'notification' cho người nhận
async function pushUserNotification({ userId, type, postId = null, payload = {} }) {
  try {
    const notif = await userNotifModel.createNotification({ userId, type, postId, payload });
    emitToUser(userId, 'notification', notif);
    return notif;
  } catch (err) {
    logger.warn({ err, userId, type }, 'Failed to push user notification');
    return null;
  }
}

// Payload chuẩn về người gây ra hành động (like/comment/kết nối)
async function actorPayload(actorId) {
  const { rows: [actor] } = await query(
    'SELECT display_name, avatar_color, avatar_url FROM users WHERE id = $1', [actorId]
  );
  return {
    fromUserId:      actorId,
    fromDisplayName: actor?.display_name ?? null,
    fromAvatarColor: actor?.avatar_color ?? null,
    fromAvatarUrl:   actor?.avatar_url   ?? null,
  };
}

// Đã có notification 'type' chưa đọc từ cùng actor cho cùng post chưa?
// Dùng để không spam khi user like/unlike/like liên tục.
async function hasRecentDuplicate({ userId, type, postId, fromUserId }) {
  const { rows } = await query(
    `SELECT 1 FROM user_notifications
     WHERE user_id = $1 AND type = $2 AND post_id = $3
       AND payload->>'fromUserId' = $4`,
    [userId, type, postId, fromUserId]
  );
  return rows.length > 0;
}

module.exports = { pushUserNotification, actorPayload, hasRecentDuplicate };
