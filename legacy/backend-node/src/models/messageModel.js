const { query, pool } = require('../config/db');
const { personaExpr } = require('../utils/personaSql');
const { escapeLike } = require('../utils/sql');
const userModel = require('./userModel');

// Fixed reaction set — kept small on purpose (Messenger-style quick react bar)
const ALLOWED_REACTION_EMOJI = ['❤️', '👍', '😂', '😮', '😢', '🔥'];

// Fixed RSVP set for meeting proposals — mirrors community_events' going/maybe/not_going
const ALLOWED_MEETING_RSVP_STATUS = ['going', 'maybe', 'not_going'];

// Shared SELECT fragment: embeds the quoted-message preview (sender name +
// truncated content), a per-message reaction summary ({ emoji: [user_id] }),
// and — for meeting proposals — the proposal itself with a per-status RSVP
// summary ({ going: [user_id], maybe: [...], not_going: [...] }), same
// map-of-user-ids convention as reactions so the client derives "my status"
// and counts without needing a requesting-user-scoped query. Also embeds a
// cheap is_pinned boolean (EXISTS against message_pins) so a chat bubble can
// show a pin indicator without a separate GET .../pins fetch. delivered_to/
// read_by are per-participant receipt arrays (message_receipts, one row per
// user per kind) — same correlated-subquery-plus-COALESCE idiom as reactions
// above, minus the GROUP BY dimension since each is a single kind filter
// rather than a map keyed by several values. Replaces the old single
// messages.status enum (removed — can't represent "read by 3 of 5" in a group).
// Requires the query to alias the messages row as `m` and join:
//   JOIN conversations c ON c.id = m.conversation_id
//   LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
//   LEFT JOIN users    ru ON ru.id = rm.sender_id
//   LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
const MESSAGE_EMBED_SELECT = `
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
                                     WHEN 'voice' THEN '🎤 Voice message'
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
       ), '{}'::jsonb) AS reactions,
       CASE WHEN mp.id IS NOT NULL THEN
         jsonb_build_object(
           'id', mp.id,
           'title', mp.title,
           'location', mp.location,
           'starts_at', mp.starts_at,
           'ends_at', mp.ends_at,
           'status', mp.status,
           'reminder_offset', mp.reminder_offset,
           'reminder_at', mp.reminder_at,
           'reminder_sent_at', mp.reminder_sent_at,
           'created_at', mp.created_at,
           'updated_at', mp.updated_at,
           'rsvps', COALESCE((
             SELECT jsonb_object_agg(agg.status, agg.user_ids)
             FROM (
               SELECT status, jsonb_agg(user_id) AS user_ids
               FROM message_meeting_rsvps
               WHERE proposal_id = mp.id
               GROUP BY status
             ) agg
           ), '{}'::jsonb)
         )
       ELSE NULL END AS meeting_proposal,
       EXISTS(SELECT 1 FROM message_pins WHERE message_id = m.id) AS is_pinned,
       COALESCE((
         SELECT jsonb_agg(mr.user_id)
         FROM message_receipts mr
         WHERE mr.message_id = m.id AND mr.kind = 'delivered'
       ), '[]'::jsonb) AS delivered_to,
       COALESCE((
         SELECT jsonb_agg(mr.user_id)
         FROM message_receipts mr
         WHERE mr.message_id = m.id AND mr.kind = 'read'
       ), '[]'::jsonb) AS read_by`;

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

// Create a new group conversation: the creator is inserted as 'owner', every
// other id in memberIds as 'member'. Cap/duplicate/self validation is the
// caller's job (messageService) — this just does the parameterized bulk insert.
async function createGroupConversation(creatorId, memberIds, mode, name) {
  const { rows } = await query(
    `INSERT INTO conversations (mode, is_group, name, created_by)
     VALUES ($1, TRUE, $2, $3)
     RETURNING id, mode, is_group, name, avatar_url, avatar_color, created_by, created_at`,
    [mode, name, creatorId]
  );
  const conversation = rows[0];

  const allMembers = [creatorId, ...memberIds];
  const params = [conversation.id];
  const placeholders = allMembers.map((uid) => {
    const role = uid === creatorId ? 'owner' : 'member';
    params.push(uid, role);
    return `($1, $${params.length - 1}, $${params.length})`;
  });

  await query(
    `INSERT INTO conversation_participants (conversation_id, user_id, role)
     VALUES ${placeholders.join(', ')}`,
    params
  );

  return conversation;
}

// Basic conversation row — used to dispatch 1:1 vs group behavior (is_group)
// and to read group metadata (name/avatar/created_by) without the members join.
async function getConversationById(conversationId) {
  const { rows } = await query(
    `SELECT id, mode, theme, is_group, name, avatar_url, avatar_color, created_by, updated_at
     FROM conversations WHERE id = $1`,
    [conversationId]
  );
  return rows[0] || null;
}

// List all conversations for a user in a given mode, ordered by most recent activity.
// Forked via UNION ALL: the 1:1 branch is byte-for-byte the original query
// (other_user_* via the other participant's JOIN), the group branch selects
// the conversation's own name/avatar + a member-count subquery instead.
async function listConversations(userId, mode) {
  const { rows } = await query(
    `(
       SELECT
         c.id, c.mode, c.is_group, c.theme, c.updated_at,
         u.id              AS other_user_id,
         u.username        AS other_user_username,
         ${personaExpr('display_name', 'c.mode')}  AS other_user_name,
         u.avatar_color    AS other_user_avatar_color,
         ${personaExpr('avatar_url', 'c.mode')}    AS other_user_avatar_url,
         u.job_title       AS other_user_job_title,
         other_cp.nickname AS other_user_nickname,
         NULL::text        AS name,
         NULL::text        AS avatar_url,
         NULL::text        AS avatar_color,
         NULL::int         AS member_count,
         my_cp.muted_until AS muted_until,
         lm.content        AS last_message_content,
         lm.message_type   AS last_message_type,
         lm.sender_id      AS last_message_sender_id,
         lm.created_at     AS last_message_at,
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
       WHERE c.mode = $2 AND c.is_group = FALSE
     )
     UNION ALL
     (
       SELECT
         c.id, c.mode, c.is_group, c.theme, c.updated_at,
         NULL::uuid        AS other_user_id,
         NULL::text        AS other_user_username,
         NULL::text        AS other_user_name,
         NULL::text        AS other_user_avatar_color,
         NULL::text        AS other_user_avatar_url,
         NULL::text        AS other_user_job_title,
         NULL::text        AS other_user_nickname,
         c.name            AS name,
         c.avatar_url      AS avatar_url,
         c.avatar_color    AS avatar_color,
         (SELECT COUNT(*)::INT FROM conversation_participants cp2
           WHERE cp2.conversation_id = c.id)                    AS member_count,
         my_cp.muted_until AS muted_until,
         lm.content        AS last_message_content,
         lm.message_type   AS last_message_type,
         lm.sender_id      AS last_message_sender_id,
         lm.created_at     AS last_message_at,
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
       LEFT JOIN LATERAL (
         SELECT CASE WHEN deleted_at IS NULL THEN content ELSE NULL END AS content,
                message_type, sender_id, created_at
         FROM messages
         WHERE conversation_id = c.id
           AND created_at > COALESCE(my_cp.cleared_at, '-infinity'::timestamptz)
         ORDER BY created_at DESC
         LIMIT 1
       ) lm ON true
       WHERE c.mode = $2 AND c.is_group = TRUE
     )
     ORDER BY updated_at DESC`,
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

  // Recalled messages: hide content/media, return is_deleted so the client can render a placeholder
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id,
            CASE WHEN m.deleted_at IS NULL THEN m.content   ELSE NULL END AS content,
            m.message_type,
            CASE WHEN m.deleted_at IS NULL THEN m.media_url ELSE NULL END AS media_url,
            CASE WHEN m.deleted_at IS NULL THEN m.voice_duration_seconds ELSE NULL END AS voice_duration_seconds,
            CASE WHEN m.deleted_at IS NULL THEN m.voice_waveform ELSE NULL END AS voice_waveform,
            m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${MESSAGE_EMBED_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
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
// voiceDurationSeconds/voiceWaveform are only ever set for messageType 'voice'
// (same optional-extra-fields shape mediaUrl already has for image/video) —
// callers simply pass null for every other message type.
async function insertMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null, replyToMessageId = null, voiceDurationSeconds = null, voiceWaveform = null }) {
  const { rows } = await query(
    `INSERT INTO messages (conversation_id, sender_id, content, message_type, media_url, reply_to_message_id, voice_duration_seconds, voice_waveform)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
     RETURNING id`,
    [conversationId, senderId, content || null, messageType, mediaUrl, replyToMessageId, voiceDurationSeconds, voiceWaveform]
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
            CASE WHEN m.deleted_at IS NULL THEN m.voice_duration_seconds ELSE NULL END AS voice_duration_seconds,
            CASE WHEN m.deleted_at IS NULL THEN m.voice_waveform ELSE NULL END AS voice_waveform,
            m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${MESSAGE_EMBED_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
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

// Mark all messages from other senders as read; update participant's
// last_read_at. Read implies delivered, so this inserts BOTH kinds in one
// statement (via a CROSS JOIN over the two kind literals) for every message
// not sent by the caller — a message can never end up "read" but not
// "delivered" in the per-kind breakdown. ON CONFLICT DO NOTHING makes
// re-marking read a safe, idempotent no-op (whichever kind rows already
// exist are simply skipped). Returns the ids of messages that gained a NEW
// 'read' receipt (i.e. were not already read), for the caller's broadcast.
async function markRead(conversationId, userId) {
  const { rows } = await query(
    `WITH ins AS (
       INSERT INTO message_receipts (message_id, user_id, kind)
       SELECT m.id, $2, k.kind
       FROM messages m
       CROSS JOIN (VALUES ('delivered'), ('read')) AS k(kind)
       WHERE m.conversation_id = $1 AND m.sender_id != $2
       ON CONFLICT (message_id, user_id, kind) DO NOTHING
       RETURNING message_id, kind
     )
     SELECT DISTINCT message_id FROM ins WHERE kind = 'read'`,
    [conversationId, userId]
  );

  await query(
    `UPDATE conversation_participants SET last_read_at = NOW()
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );

  return rows.map((r) => r.message_id);
}

// Mark a single message delivered (live path, driven by the recipient's socket
// the instant it receives 'new_message'). Upgrade-only via
// INSERT ... ON CONFLICT DO NOTHING against message_receipts(kind='delivered')
// — RETURNING only surfaces rows that were actually newly inserted, so a
// second call is a safe no-op that returns null (nothing to notify). Never
// touches/removes an existing 'read' receipt (separate row under the
// composite PK), so a read message can never be "downgraded" back to
// delivered-only. Returns the same { id, conversation_id, sender_id } shape
// the caller (messageService.deliverMessage / index.js) already expects.
async function markMessageDelivered(messageId, userId) {
  const { rows } = await query(
    `WITH ins AS (
       INSERT INTO message_receipts (message_id, user_id, kind)
       SELECT m.id, $2, 'delivered'
       FROM messages m
       WHERE m.id = $1 AND m.sender_id != $2
       ON CONFLICT (message_id, user_id, kind) DO NOTHING
       RETURNING message_id
     )
     SELECT m.id, m.conversation_id, m.sender_id
     FROM ins JOIN messages m ON m.id = ins.message_id`,
    [messageId, userId]
  );
  return rows[0] || null;
}

// Mark every outstanding message in a conversation delivered (REST catch-up
// path for when the recipient was offline). Same upgrade-only ON CONFLICT DO
// NOTHING guard as markMessageDelivered, batched over the whole conversation.
// Returns one { id, sender_id } row per message that actually gained a new
// 'delivered' receipt, so the caller can notify each sender.
async function markConversationDelivered(conversationId, userId) {
  const { rows } = await query(
    `WITH ins AS (
       INSERT INTO message_receipts (message_id, user_id, kind)
       SELECT m.id, $2, 'delivered'
       FROM messages m
       WHERE m.conversation_id = $1 AND m.sender_id != $2
       ON CONFLICT (message_id, user_id, kind) DO NOTHING
       RETURNING message_id
     )
     SELECT m.id, m.sender_id
     FROM ins JOIN messages m ON m.id = ins.message_id`,
    [conversationId, userId]
  );
  return rows;
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

// Recall a message — only the sender can recall it, soft delete
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

// Settings snapshot for the 1:1 settings screen: shared theme, caller's mute,
// other user info. Renamed from getSettings (behavior unchanged) now that
// getGroupSettings exists as the group counterpart — the two stay as simple
// separate functions rather than one function branching internally.
async function getSettings1to1(conversationId, userId) {
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

// Settings snapshot for the group settings screen: group name/avatar/theme +
// the full member list (each with their persona-aware display info + role).
async function getGroupSettings(conversationId, userId) {
  const { rows: convRows } = await query(
    `SELECT id, mode, theme, name, avatar_url, avatar_color, created_by
     FROM conversations WHERE id = $1 AND is_group = TRUE`,
    [conversationId]
  );
  const conversation = convRows[0];
  if (!conversation) return null;

  const { rows: members } = await query(
    `SELECT u.id, u.username,
            ${personaExpr('display_name', 'c.mode')} AS display_name,
            u.avatar_color AS avatar_color,
            ${personaExpr('avatar_url', 'c.mode')}   AS avatar_url,
            cp.role, cp.joined_at
     FROM conversation_participants cp
     JOIN conversations c ON c.id = cp.conversation_id
     JOIN users u ON u.id = cp.user_id
     WHERE cp.conversation_id = $1
     ORDER BY cp.joined_at ASC`,
    [conversationId]
  );

  return {
    id: conversation.id,
    theme: conversation.theme,
    name: conversation.name,
    avatar_url: conversation.avatar_url,
    avatar_color: conversation.avatar_color,
    created_by: conversation.created_by,
    members,
  };
}

// ── Group membership & metadata ────────────────────────────────────────────

// Bulk-add participants as 'member' (caller enforces the 100-member cap and
// dedupes against current members before calling). Idempotent: re-adding an
// already-present member is a no-op rather than an error.
async function addParticipants(conversationId, userIds) {
  if (!userIds.length) return;
  const params = [conversationId];
  const placeholders = userIds.map((uid) => {
    params.push(uid);
    return `($1, $${params.length}, 'member')`;
  });
  await query(
    `INSERT INTO conversation_participants (conversation_id, user_id, role)
     VALUES ${placeholders.join(', ')}
     ON CONFLICT (conversation_id, user_id) DO NOTHING`,
    params
  );
}

// Remove one participant from a group (kick, or self on leave)
async function removeParticipant(conversationId, userId) {
  await query(
    `DELETE FROM conversation_participants WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
}

// Update a group's name/avatar fields (only the fields actually passed are touched)
async function updateGroupInfo(conversationId, { name, avatarUrl, avatarColor } = {}) {
  const sets = [];
  const params = [conversationId];
  if (name !== undefined) {
    params.push(name);
    sets.push(`name = $${params.length}`);
  }
  if (avatarUrl !== undefined) {
    params.push(avatarUrl);
    sets.push(`avatar_url = $${params.length}`);
  }
  if (avatarColor !== undefined) {
    params.push(avatarColor);
    sets.push(`avatar_color = $${params.length}`);
  }
  if (!sets.length) return;
  await query(`UPDATE conversations SET ${sets.join(', ')} WHERE id = $1`, params);
}

// Transfer ownership atomically: fromUserId -> 'member', toUserId -> 'owner'.
// Runs inside an explicit transaction (via pool.connect()/BEGIN/COMMIT, same
// shape as updateMeetingProposal below) so a crash between the two UPDATEs
// can never leave the group with zero owners.
async function transferOwnership(conversationId, fromUserId, toUserId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `UPDATE conversation_participants SET role = 'member'
       WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, fromUserId]
    );
    await client.query(
      `UPDATE conversation_participants SET role = 'owner'
       WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId, toUserId]
    );
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Current member count — used to re-check the 100-member cap against
// current + new count before an addMembers call proceeds.
async function getGroupMemberCount(conversationId) {
  const { rows } = await query(
    `SELECT COUNT(*)::INT AS count FROM conversation_participants WHERE conversation_id = $1`,
    [conversationId]
  );
  return rows[0].count;
}

// A single participant's role ('owner'/'member'), or null if not a participant
async function getParticipantRole(conversationId, userId) {
  const { rows } = await query(
    `SELECT role FROM conversation_participants WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
  return rows[0] ? rows[0].role : null;
}

// All participants with role/joined_at, oldest first — used by leaveGroup to
// find the earliest-joined remaining member to auto-promote.
async function listParticipantsOrderedByJoin(conversationId) {
  const { rows } = await query(
    `SELECT user_id, role, joined_at FROM conversation_participants
     WHERE conversation_id = $1 ORDER BY joined_at ASC`,
    [conversationId]
  );
  return rows;
}

// ── Group nicknames (setter+target pair; 1:1 nicknames are untouched above) ─

// Upsert the caller's nickname for a target member in a group conversation
async function setGroupNickname(conversationId, setterId, targetId, nickname) {
  await query(
    `INSERT INTO conversation_nicknames (conversation_id, setter_id, target_id, nickname, updated_at)
     VALUES ($1, $2, $3, $4, NOW())
     ON CONFLICT (conversation_id, setter_id, target_id)
     DO UPDATE SET nickname = EXCLUDED.nickname, updated_at = NOW()`,
    [conversationId, setterId, targetId, nickname]
  );
}

// Clear the caller's nickname for a target member (nickname set back to null)
async function deleteGroupNickname(conversationId, setterId, targetId) {
  await query(
    `DELETE FROM conversation_nicknames
     WHERE conversation_id = $1 AND setter_id = $2 AND target_id = $3`,
    [conversationId, setterId, targetId]
  );
}

// Nicknames the viewer has set in this group: { target_id: nickname }.
// Scoped to setter_id = viewerId only — never leaks another member's private
// nickname choice for the same target.
async function getGroupNicknames(conversationId, viewerId) {
  const { rows } = await query(
    `SELECT target_id, nickname FROM conversation_nicknames
     WHERE conversation_id = $1 AND setter_id = $2`,
    [conversationId, viewerId]
  );
  const map = {};
  rows.forEach((r) => { map[r.target_id] = r.nickname; });
  return map;
}

// ── Group block acknowledgement (alert-only block handling in groups) ──────

// Ids of OTHER participants the caller has blocked, or who have blocked the
// caller (either direction). A small per-participant loop over the existing
// isBlockedEitherWay check — the participant lists here are small (<=100),
// so a batch query isn't worth the complexity for v1.
async function getBlockedIdsInConversation(conversationId, userId) {
  const others = (await getParticipants(conversationId)).filter((uid) => uid !== userId);
  const blocked = [];
  for (const otherId of others) {
    if (await userModel.isBlockedEitherWay(userId, otherId)) blocked.push(otherId);
  }
  return blocked;
}

// The caller's last-acknowledged blocked-set snapshot for this conversation
async function getBlockAck(conversationId, userId) {
  const { rows } = await query(
    `SELECT acked_blocked_ids, acked_at FROM conversation_block_acks
     WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId]
  );
  return rows[0] || null;
}

// Upsert the caller's acknowledgement of the current blocked-id-set (stored
// as a sorted, comma-joined string so future comparisons are a cheap string diff)
async function setBlockAck(conversationId, userId, blockedIds) {
  const snapshot = blockedIds.slice().sort().join(',');
  await query(
    `INSERT INTO conversation_block_acks (conversation_id, user_id, acked_blocked_ids, acked_at)
     VALUES ($1, $2, $3, NOW())
     ON CONFLICT (conversation_id, user_id)
     DO UPDATE SET acked_blocked_ids = EXCLUDED.acked_blocked_ids, acked_at = NOW()`,
    [conversationId, userId, snapshot]
  );
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
  term = escapeLike(term);
  const { rows } = await query(
    `SELECT m.id, m.conversation_id, m.sender_id, m.content,
            m.message_type, m.media_url, m.created_at, m.reply_to_message_id,
            (m.deleted_at IS NOT NULL) AS is_deleted,
${MESSAGE_EMBED_SELECT}
     FROM messages m
     JOIN conversations c ON c.id = m.conversation_id
     LEFT JOIN messages rm ON rm.id = m.reply_to_message_id
     LEFT JOIN users    ru ON ru.id = rm.sender_id
     LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
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

// ── Meeting proposals ───────────────────────────────────────────────────────

// Create a proposal row for a just-inserted 'meeting' message. reminderOffset/
// reminderAt are always present by the time this is called — messageService.
// validateMeetingProposal fills in a default when a caller doesn't send one.
async function createMeetingProposal(messageId, { title, location, startsAt, endsAt, reminderOffset, reminderAt }) {
  const { rows } = await query(
    `INSERT INTO message_meeting_proposals
       (message_id, title, location, starts_at, ends_at, reminder_offset, reminder_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     RETURNING *`,
    [messageId, title, location || null, startsAt, endsAt || null, reminderOffset, reminderAt]
  );
  return rows[0];
}

// Reschedule: update the proposal's fields and clear all existing RSVPs —
// a response to the old time shouldn't silently carry over to the new one.
// Also resets reminder_sent_at to NULL so a rescheduled meeting's reminder
// re-arms against the new reminder_at instead of staying permanently
// "already sent" from before the reschedule. All three statements run
// inside one transaction so a failure between them can't leave stale RSVPs
// or a stuck reminder_sent_at attached to a rescheduled proposal.
async function updateMeetingProposal(proposalId, { title, location, startsAt, endsAt, reminderOffset, reminderAt }) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const { rows } = await client.query(
      `UPDATE message_meeting_proposals
       SET title = $2, location = $3, starts_at = $4, ends_at = $5,
           reminder_offset = $6, reminder_at = $7, reminder_sent_at = NULL,
           updated_at = NOW()
       WHERE id = $1
       RETURNING *`,
      [proposalId, title, location || null, startsAt, endsAt || null, reminderOffset, reminderAt]
    );

    await client.query(`DELETE FROM message_meeting_rsvps WHERE proposal_id = $1`, [proposalId]);

    await client.query('COMMIT');
    return rows[0];
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Cancel a proposal (soft — status flag, message bubble stays in place)
async function cancelMeetingProposal(proposalId) {
  const { rows } = await query(
    `UPDATE message_meeting_proposals SET status = 'cancelled', updated_at = NOW()
     WHERE id = $1
     RETURNING *`,
    [proposalId]
  );
  return rows[0];
}

// Upsert a participant's RSVP (going/maybe/not_going) for a proposal — the
// write is itself conditional on the proposal still being 'active' (WHERE
// EXISTS guard on the source SELECT) instead of a separate check-then-act,
// so an RSVP can never land against a proposal that was just
// cancelled/rescheduled. Returns the written row, or null if the guard
// failed (proposal missing or no longer active) — the caller maps a null
// result to the "cannot respond to a cancelled meeting" error.
async function setMeetingRsvp(proposalId, userId, status) {
  const { rows } = await query(
    `INSERT INTO message_meeting_rsvps (proposal_id, user_id, status)
     SELECT $1, $2, $3
     WHERE EXISTS (
       SELECT 1 FROM message_meeting_proposals WHERE id = $1 AND status = 'active'
     )
     ON CONFLICT (proposal_id, user_id)
     DO UPDATE SET status = $3, responded_at = NOW()
     RETURNING proposal_id`,
    [proposalId, userId, status]
  );
  return rows[0] || null;
}

// Fetch a proposal alongside its message's conversation/sender/type, keyed by
// message_id — used when the caller only has the message id (e.g. the
// REST/socket routes address proposals via :messageId). Requires the message
// to not be recalled: a recalled meeting proposal must be genuinely inert
// server-side (RSVP/reschedule/cancel all 404), not just hidden client-side.
async function getProposalByMessageId(messageId) {
  const { rows } = await query(
    `SELECT mp.id, mp.status, mp.title, mp.location, mp.starts_at, mp.ends_at,
            mp.reminder_offset, mp.reminder_at, mp.reminder_sent_at,
            m.id AS message_id, m.conversation_id, m.sender_id, m.message_type
     FROM messages m
     LEFT JOIN message_meeting_proposals mp ON mp.message_id = m.id
     WHERE m.id = $1 AND m.deleted_at IS NULL`,
    [messageId]
  );
  return rows[0] || null;
}

// ── Meeting reminders (meetingReminderJob.js) ──────────────────────────────

// Active proposals whose reminder is due and hasn't been sent yet. The
// job's dedupe guard (reminder_sent_at IS NULL) is baked into the WHERE
// clause itself, not a separate check-then-act, mirroring setMeetingRsvp's
// guarded-write convention above.
async function getDueMeetingReminders() {
  const { rows } = await query(
    `SELECT mp.id, mp.title, mp.starts_at, m.id AS message_id, m.conversation_id
     FROM message_meeting_proposals mp
     JOIN messages m ON m.id = mp.message_id
     WHERE mp.status = 'active' AND mp.reminder_sent_at IS NULL AND mp.reminder_at <= NOW()`
  );
  return rows;
}

// User ids who RSVP'd 'going' to a proposal — the reminder recipient set
// for a group meeting (1:1 meetings notify both participants unconditionally
// instead, no RSVP involved).
async function getGoingRsvpUserIds(proposalId) {
  const { rows } = await query(
    `SELECT user_id FROM message_meeting_rsvps WHERE proposal_id = $1 AND status = 'going'`,
    [proposalId]
  );
  return rows.map((r) => r.user_id);
}

// Mark a proposal's reminder as sent — the job's dedupe guard for every
// future run (including a concurrent run for the same sweep).
async function markMeetingReminderSent(proposalId) {
  await query(
    `UPDATE message_meeting_proposals SET reminder_sent_at = NOW() WHERE id = $1`,
    [proposalId]
  );
}

// ── Message pins ────────────────────────────────────────────────────────────

// Cap on simultaneous pins per conversation (enforced inside the INSERT below)
const MAX_PINS_PER_CONVERSATION = 10;

// Pin a message — the write itself is guarded by a COUNT(*) < 10 subquery
// (mirrors setMeetingRsvp's "guard the write, not a separate check-then-act"
// style), so a race between two concurrent pins can never push the count past
// the cap. Returns the inserted row, or null if the cap was already hit (the
// caller — messageService.pinMessage — maps null to a 400 error).
// Idempotency: re-pinning an already-pinned message hits the
// UNIQUE(conversation_id, message_id) constraint and the unique-violation
// error (code 23505) surfaces to the caller as-is — documented choice over a
// silent no-op, since re-pinning with a *different* expires_at would
// otherwise be silently ignored instead of updating the expiry.
async function pinMessage(conversationId, messageId, userId, expiresAt) {
  const { rows } = await query(
    `INSERT INTO message_pins (conversation_id, message_id, pinned_by, expires_at)
     SELECT $1, $2, $3, $4
     WHERE (SELECT COUNT(*) FROM message_pins WHERE conversation_id = $1) < $5
     RETURNING *`,
    [conversationId, messageId, userId, expiresAt || null, MAX_PINS_PER_CONVERSATION]
  );
  return rows[0] || null;
}

// Unpin a message — any participant may call this (enforced by the caller).
// Returns the deleted row, or null if it wasn't pinned.
async function unpinMessage(conversationId, messageId) {
  const { rows } = await query(
    `DELETE FROM message_pins WHERE conversation_id = $1 AND message_id = $2 RETURNING *`,
    [conversationId, messageId]
  );
  return rows[0] || null;
}

// List a conversation's pins, newest-pinned first, joined to the pinned
// message + its sender. A recalled (soft-deleted) message stays in the pin
// list — marked is_deleted, content hidden — rather than vanishing or
// erroring, same convention as MESSAGE_EMBED_SELECT's replied-message preview.
async function listPins(conversationId) {
  const { rows } = await query(
    `SELECT mp.id, mp.message_id, mp.pinned_by, mp.pinned_at, mp.expires_at,
            m.conversation_id,
            m.message_type,
            (m.deleted_at IS NOT NULL) AS is_deleted,
            CASE WHEN m.deleted_at IS NULL THEN m.content ELSE NULL END AS content,
            m.sender_id,
            ${personaExpr('display_name', 'c.mode', 'u')} AS sender_name
     FROM message_pins mp
     JOIN messages m ON m.id = mp.message_id
     JOIN conversations c ON c.id = m.conversation_id
     JOIN users u ON u.id = m.sender_id
     WHERE mp.conversation_id = $1
     ORDER BY mp.pinned_at DESC`,
    [conversationId]
  );
  return rows;
}

// Sweep every pin whose expires_at has passed. Returns the deleted rows
// (conversation_id + message_id) so the caller/job can broadcast a
// 'pin_removed' event per conversation.
async function deleteExpiredPins() {
  const { rows } = await query(
    `DELETE FROM message_pins WHERE expires_at IS NOT NULL AND expires_at <= NOW()
     RETURNING conversation_id, message_id`
  );
  return rows;
}

module.exports = {
  ALLOWED_REACTION_EMOJI,
  ALLOWED_MEETING_RSVP_STATUS,
  findConversation,
  createConversation,
  createGroupConversation,
  getConversationById,
  listConversations,
  listMessages,
  insertMessage,
  getMessageById,
  getMessageBasic,
  recallMessage,
  markRead,
  markMessageDelivered,
  markConversationDelivered,
  totalUnread,
  getParticipants,
  isParticipant,
  getSettings1to1,
  getGroupSettings,
  updateTheme,
  setNickname,
  setMute,
  clearConversation,
  listMedia,
  searchMessages,
  setReaction,
  getReactions,
  createMeetingProposal,
  updateMeetingProposal,
  cancelMeetingProposal,
  setMeetingRsvp,
  getProposalByMessageId,
  getDueMeetingReminders,
  getGoingRsvpUserIds,
  markMeetingReminderSent,
  // Group membership & metadata
  addParticipants,
  removeParticipant,
  updateGroupInfo,
  transferOwnership,
  getGroupMemberCount,
  getParticipantRole,
  listParticipantsOrderedByJoin,
  // Group nicknames
  setGroupNickname,
  deleteGroupNickname,
  getGroupNicknames,
  // Group block acknowledgement
  getBlockedIdsInConversation,
  getBlockAck,
  setBlockAck,
  // Message pins
  MAX_PINS_PER_CONVERSATION,
  pinMessage,
  unpinMessage,
  listPins,
  deleteExpiredPins,
};
