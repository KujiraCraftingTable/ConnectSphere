const { query } = require('../config/db');
const { personaExpr } = require('../utils/personaSql');

// Fixed reaction set — kept small on purpose (Messenger-style quick react bar)
const ALLOWED_REACTION_EMOJI = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

// Shared SELECT fragment: embeds the quoted-message preview (sender name +
// truncated content) and a per-message reaction summary ({ emoji: [user_id] }).
// Requires the query to alias the messages row as `m` and join:
//   JOIN conversations c ON c.id = m.conversation_id
//   LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
//   LEFT JOIN users    ru ON ru.id = rm.sender_id
const REPLY_AND_REACTIONS_SELECT = `
       CASE WHEN rm.id IS NOT NULL THEN
         jsonb_build_object(
           'id', rm.id,
           'sender_id', rm.sender_id,
           'sender_name', ${personaExpr('display_name', 'c.mode', 'ru')},
           'message_type', rm.message_type,
           'is_deleted', (rm.deleted_at IS NOT NULL),
           'content', CASE WHEN rm.deleted_at IS NOT NULL THEN NULL
                            ELSE LEFT(COALESCE(rm.content,
                                   CASE rm.message_type
                                     WHEN 'image' THEN '📷 Photo'
                                     WHEN 'video' THEN '🎥 Video'
                                     ELSE ''
                                   END
                                 ), 120)
                       END
         )
       ELSE NULL END AS replied_message,
       COALESCE((
         SELECT jsonb_object_agg(agg.emoji, agg.user_ids)
         FROM (
           SELECT emoji, jsonb_agg(user_id) AS user_ids
           FROM message_reactions
           WHERE message_id = m.id
           GROUP BY emoji
         ) agg
       ), '{}'::jsonb) AS reactions`;

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
       c.theme,
       c.updated_at,
       u.id            AS other_user_id,
       u.username      AS other_user_username,
       ${personaExpr('display_name', 'c.mode')}  AS other_user_name,
       u.avatar_color  AS other_user_avatar_color,
       ${personaExpr('avatar_url', 'c.mode')}    AS other_user_avatar_url,
       u.job_title     AS other_user_job_title,
       other_cp.nickname AS other_user_nickname,
       my_cp.muted_until AS muted_until,
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
           AND m.created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
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
         AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
       ORDER BY created_at DESC
       LIMIT 1
     ) lm ON true
     WHERE c.mode = $2
     ORDER BY c.updated_at DESC`,
    [userId, mode]
  );
  return rows;
}

// Fetch messages for a conversation (cursor-based, newest first).
// Respects the caller's cleared_at ("delete on my side"): only messages newer
// than that marker are returned.
async function listMessages(conversationId, userId, { limit = 30, before = null }) {
  const params = [conversationId, limit, userId];
  const beforeClause = before ? `AND m.created_at < $4` : '';
  if (before) params.push(before);

  // Tin đã thu hồi: giấu content/media, trả is_deleted để client render placeholder
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id,
            CASE WHEN m.deleted_at IS NULL THEN m.content   ELSE NULL END AS content,
            m.message_type,
            CASE WHEN m.deleted_at IS NULL THEN m.media_url ELSE NULL END AS media_url,
            m.status, m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${REPLY_AND_REACTIONS_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     WHERE m.conversation_id = $1
       AND m.created_at > COALESCE(
         (SELECT cleared_at FROM conversation_participants
           WHERE conversation_id = $1 AND user_id = $3),
         '-infinity'::timestamptz)
       ${beforeClause}
     ORDER BY m.created_at DESC
     LIMIT $2`,
    params
  );
  return rows;
}

// Insert a new message and bump conversation.updated_at.
// Returns the full row (incl. embedded reply preview) via getMessageById so the
// caller never needs a second round-trip to render a reply's quoted content.
async function insertMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null, replyToMessageId = null }) {
  const { rows } = await query(
    `INSERT INTO messages (conversation_id, sender_id, content, message_type, media_url, reply_to_message_id)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id`,
    [conversationId, senderId, content || null, messageType, mediaUrl, replyToMessageId]
  );

  await query(
    `UPDATE conversations SET updated_at = NOW() WHERE id = $1`,
    [conversationId]
  );

  return getMessageById(rows[0].id);
}

// Fetch one message with its embedded reply preview + reaction summary.
// Used after insert and after a reaction change (both need the fresh shape).
async function getMessageById(messageId) {
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id,
            CASE WHEN m.deleted_at IS NULL THEN m.content   ELSE NULL END AS content,
            m.message_type,
            CASE WHEN m.deleted_at IS NULL THEN m.media_url ELSE NULL END AS media_url,
            m.status, m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${REPLY_AND_REACTIONS_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     WHERE m.id = $1`,
    [messageId]
  );
  return rows[0] || null;
}

// Basic fields only — used to validate a reply target belongs to the conversation
// without paying for the full reply/reaction join.
async function getMessageBasic(messageId) {
  const { rows } = await query(
    `SELECT id, conversation_id FROM messages WHERE id = $1`,
    [messageId]
  );
  return rows[0] || null;
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

// ── Conversation settings (nickname, theme, mute, clear) ──────────────────────

// Settings snapshot for the settings screen: shared theme, caller's mute, other user info
async function getSettings(conversationId, userId) {
  const { rows } = await query(
    `SELECT c.theme,
            my.muted_until,
            u.id           AS other_user_id,
            u.username     AS other_user_username,
            ${personaExpr('display_name', 'c.mode')} AS other_user_name,
            u.avatar_color AS other_user_avatar_color,
            u.job_title    AS other_user_job_title,
            other.nickname AS other_user_nickname
     FROM conversations c
     JOIN conversation_participants my
          ON my.conversation_id = c.id AND my.user_id = $2
     JOIN conversation_participants other
          ON other.conversation_id = c.id AND other.user_id != $2
     JOIN users u ON u.id = other.user_id
     WHERE c.id = $1`,
    [conversationId, userId]
  );
  return rows[0] || null;
}

// Update the conversation's shared chat theme (both participants see it)
async function updateTheme(conversationId, theme) {
  await query(`UPDATE conversations SET theme = $2 WHERE id = $1`, [conversationId, theme]);
}

// Set the shared nickname for a target participant in a conversation
async function setNickname(conversationId, targetUserId, nickname) {
  await query(
    `UPDATE conversation_participants SET nickname = $3
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, targetUserId, nickname]
  );
}

// Set the caller's own mute for a conversation.
//   minutes: null → unmute, negative → until turned back on (far-future date),
//            N>0 → N minutes. A far-future date is used instead of 'infinity'
//            because node-postgres serialises 'infinity' as JSON null.
async function setMute(conversationId, userId, minutes) {
  const { rows } = await query(
    `UPDATE conversation_participants
     SET muted_until = CASE
           WHEN $3::int IS NULL THEN NULL
           WHEN $3 < 0          THEN NOW() + INTERVAL '100 years'
           ELSE NOW() + ($3 || ' minutes')::interval
         END
     WHERE conversation_id = $1 AND user_id = $2
     RETURNING muted_until`,
    [conversationId, userId, minutes]
  );
  return rows[0] ? rows[0].muted_until : null;
}

// "Delete on my side": hide all existing messages from this user only
async function clearConversation(conversationId, userId) {
  await query(
    `UPDATE conversation_participants SET cleared_at = NOW()
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
}

// Media (images/videos) sent in a conversation, respecting the caller's cleared_at
async function listMedia(conversationId, userId) {
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id, m.message_type, m.media_url, m.created_at
     FROM messages m
     WHERE m.conversation_id = $1
       AND m.message_type IN ('image', 'video')
       AND m.deleted_at IS NULL
       AND m.created_at > COALESCE(
         (SELECT cleared_at FROM conversation_participants
           WHERE conversation_id = $1 AND user_id = $2),
         '-infinity'::timestamptz)
     ORDER BY m.created_at DESC`,
    [conversationId, userId]
  );
  return rows;
}

// Case-insensitive substring search over a conversation's text messages
async function searchMessages(conversationId, userId, term) {
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id, m.content,
            m.message_type, m.media_url, m.status, m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${REPLY_AND_REACTIONS_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     WHERE m.conversation_id = $1
       AND m.deleted_at IS NULL
       AND m.message_type = 'text'
       AND m.content ILIKE '%' || $3 || '%'
       AND m.created_at > COALESCE(
         (SELECT cleared_at FROM conversation_participants
           WHERE conversation_id = $1 AND user_id = $2),
         '-infinity'::timestamptz)
     ORDER BY m.created_at DESC
     LIMIT 50`,
    [conversationId, userId, term]
  );
  return rows;
}

// ── Reactions ───────────────────────────────────────────────────────────────

// Toggle/replace a user's reaction on a message:
//   • no existing reaction        → insert
//   • existing reaction, same     → delete (toggle off)
//   • existing reaction, different → replace (upsert)
// Returns the message's fresh reaction summary ({ emoji: [user_id, ...] }).
async function setReaction(messageId, userId, emoji) {
  const { rows: existing } = await query(
    `SELECT emoji FROM message_reactions WHERE message_id = $1 AND user_id = $2`,
    [messageId, userId]
  );

  if (existing[0] && existing[0].emoji === emoji) {
    await query(
      `DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2`,
      [messageId, userId]
    );
  } else {
    await query(
      `INSERT INTO message_reactions (message_id, user_id, emoji)
       VALUES ($1, $2, $3)
       ON CONFLICT (message_id, user_id)
       DO UPDATE SET emoji = EXCLUDED.emoji, created_at = NOW()`,
      [messageId, userId, emoji]
    );
  }

  return getReactions(messageId);
}

// Reaction summary for one message: { emoji: [user_id, ...] }
async function getReactions(messageId) {
  const { rows } = await query(
    `SELECT emoji, jsonb_agg(user_id) AS user_ids
     FROM message_reactions
     WHERE message_id = $1
     GROUP BY emoji`,
    [messageId]
  );
  const summary = {};
  rows.forEach((r) => { summary[r.emoji] = r.user_ids; });
  return summary;
}

module.exports = {
  ALLOWED_REACTION_EMOJI,
  findConversation,
  createConversation,
  listConversations,
  listMessages,
  insertMessage,
  getMessageById,
  getMessageBasic,
  recallMessage,
  markRead,
  totalUnread,
  getParticipants,
  isParticipant,
  getSettings,
  updateTheme,
  setNickname,
  setMute,
  clearConversation,
  listMedia,
  searchMessages,
  setReaction,
  getReactions,
};
