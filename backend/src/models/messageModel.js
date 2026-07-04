const { query } = require('../config/db');

// Find existing 1-on-1 conversation between two users for a given mode
async function findConversation(userA, userB, mode) {
  const { rows } = await query(
    `SELECT c.id
     FROM conversations c
     JOIN conversation_participants p1 ON p1.conversation_id = c.id AND p1.user_id = $1
     JOIN conversation_participants p2 ON p2.conversation_id = c.id AND p2.user_id = $2
     WHERE c.mode = $3`,
    [userA, userB, mode]
  );
  return rows[0] || null;
}

// Create a new conversation and add both participants
async function createConversation(userA, userB, mode) {
  const { rows } = await query(
    `INSERT INTO conversations (mode) VALUES ($1) RETURNING id`,
    [mode]
  );
  const conversationId = rows[0].id;

  await query(
    `INSERT INTO conversation_participants (conversation_id, user_id)
     VALUES ($1, $2), ($1, $3)`,
    [conversationId, userA, userB]
  );

  return { id: conversationId };
}

// List all conversations for a user in a given mode, ordered by most recent activity
async function listConversations(userId, mode) {
  const { rows } = await query(
    `SELECT
       c.id,
       c.mode,
       c.updated_at,
       u.id            AS other_user_id,
       u.username      AS other_user_username,
       u.display_name  AS other_user_name,
       u.avatar_color  AS other_user_avatar_color,
       u.avatar_url    AS other_user_avatar_url,
       u.job_title     AS other_user_job_title,
       lm.content      AS last_message_content,
       lm.message_type AS last_message_type,
       lm.sender_id    AS last_message_sender_id,
       lm.created_at   AS last_message_at,
       (
         SELECT COUNT(*)::INT
         FROM messages m
         WHERE m.conversation_id = c.id
           AND m.sender_id != $1
           AND (my_cp.last_read_at IS NULL OR m.created_at > my_cp.last_read_at)
       ) AS unread_count
     FROM conversations c
     JOIN conversation_participants my_cp
          ON my_cp.conversation_id = c.id AND my_cp.user_id = $1
     JOIN conversation_participants other_cp
          ON other_cp.conversation_id = c.id AND other_cp.user_id != $1
     JOIN users u ON u.id = other_cp.user_id
     LEFT JOIN LATERAL (
       SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content,
              message_type, sender_id, created_at
       FROM messages
       WHERE conversation_id = c.id
       ORDER BY created_at DESC
       LIMIT 1
     ) lm ON true
     WHERE c.mode = $2
     ORDER BY c.updated_at DESC`,
    [userId, mode]
  );
  return rows;
}

// Fetch messages for a conversation (cursor-based, newest first)
async function listMessages(conversationId, { limit = 30, before = null }) {
  const params = [conversationId, limit];
  const beforeClause = before
    ? `AND m.created_at < $3`
    : '';
  if (before) params.push(before);

  // Tin đã thu hồi: giấu content/media, trả is_deleted để client render placeholder
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id,
            CASE WHEN m.deleted_at IS NULL THEN m.content   ELSE NULL END AS content,
            m.message_type,
            CASE WHEN m.deleted_at IS NULL THEN m.media_url ELSE NULL END AS media_url,
            m.status, m.created_at,
            (m.deleted_at IS NOT NULL) AS is_deleted
     FROM messages m
     WHERE m.conversation_id = $1
       ${beforeClause}
     ORDER BY m.created_at DESC
     LIMIT $2`,
    params
  );
  return rows;
}

// Insert a new message and bump conversation.updated_at
async function insertMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null }) {
  const { rows } = await query(
    `INSERT INTO messages (conversation_id, sender_id, content, message_type, media_url)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id, conversation_id, sender_id, content, message_type, media_url, status, created_at`,
    [conversationId, senderId, content || null, messageType, mediaUrl]
  );

  await query(
    `UPDATE conversations SET updated_at = NOW() WHERE id = $1`,
    [conversationId]
  );

  return rows[0];
}

// Mark all messages from the other user as read; update participant's last_read_at
async function markRead(conversationId, userId) {
  await query(
    `UPDATE messages SET status = 'read'
     WHERE conversation_id = $1 AND sender_id != $2 AND status != 'read'`,
    [conversationId, userId]
  );

  await query(
    `UPDATE conversation_participants SET last_read_at = NOW()
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
}

// Total unread message count across all conversations for a user (used for badge)
async function totalUnread(userId, mode) {
  const { rows } = await query(
    `SELECT COALESCE(SUM(
       (SELECT COUNT(*)
        FROM messages m
        WHERE m.conversation_id = c.id
          AND m.sender_id != $1
          AND (cp.last_read_at IS NULL OR m.created_at > cp.last_read_at)
       )
     ), 0) AS total
     FROM conversations c
     JOIN conversation_participants cp
          ON cp.conversation_id = c.id AND cp.user_id = $1
     WHERE c.mode = $2`,
    [userId, mode]
  );
  return parseInt(rows[0].total, 10);
}

// Thu hồi tin nhắn — chỉ người gửi thu hồi được, soft delete
async function recallMessage(messageId, conversationId, senderId) {
  const { rows } = await query(
    `UPDATE messages SET deleted_at = NOW()
     WHERE id = $1 AND conversation_id = $2 AND sender_id = $3 AND deleted_at IS NULL
     RETURNING id`,
    [messageId, conversationId, senderId]
  );
  return rows[0] || null;
}

// All participant user ids of a conversation (for realtime fan-out)
async function getParticipants(conversationId) {
  const { rows } = await query(
    `SELECT user_id FROM conversation_participants WHERE conversation_id = $1`,
    [conversationId]
  );
  return rows.map((r) => r.user_id);
}

// Verify that a user is a participant in a conversation
async function isParticipant(conversationId, userId) {
  const { rows } = await query(
    `SELECT 1 FROM conversation_participants
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
  return rows.length > 0;
}

module.exports = {
  findConversation,
  createConversation,
  listConversations,
  listMessages,
  insertMessage,
  recallMessage,
  markRead,
  totalUnread,
  getParticipants,
  isParticipant,
};
