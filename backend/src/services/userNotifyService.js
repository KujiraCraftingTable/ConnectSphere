/**
 * userNotifyService.js — the ONLY way a notification is created.
 *
 * Every source (social, community, chat) funnels through here so that writing
 * a row and pushing it over Socket.IO can never drift apart. Community
 * notifications in particular used to be written with no realtime emit at all.
 *
 * Notification failures must never fail the request that triggered them, so
 * every public function swallows its own errors and logs a warning.
 */

const userNotifModel = require('../models/userNotificationModel');
const messageModel   = require('../models/messageModel');
const { query }      = require('../config/db');
const { emitToUser } = require('../utils/realtime');
const { personaExpr } = require('../utils/personaSql');
const logger         = require('../utils/logger');
const {
  isKnownType, entityTypeOf, categoryOf, typesForCategory,
  buildGroupKey, buildDestination, CATEGORIES,
} = require('../utils/notificationTypes');

// Socket fan-out cap. Rows are ALWAYS written for every recipient; beyond this
// many, the remainder pick the notification up on their next fetch instead of
// a live push. Protects against a broadcast storm in a large community.
const MAX_FANOUT_EMITS = 500;

// Chat previews are truncated to keep the inbox row readable.
const PREVIEW_LENGTH = 120;

/** Shape a stored row into the object the API and socket events both send. */
function toNotificationDTO(row) {
  if (!row) return null;
  return {
    ...row,
    group_key:   row.group_key ?? buildGroupKey(row.type, row.id),
    category:    categoryOf(row.type),
    destination: buildDestination(row),
  };
}

/** Total unread plus the per-category breakdown, for badges. */
async function unreadSummary(userId) {
  const byType = await userNotifModel.getUnreadCounts(userId);
  const byCategory = Object.fromEntries(CATEGORIES.map((c) => [c, 0]));
  let unread = 0;

  for (const { type, count } of byType) {
    unread += count;
    const category = categoryOf(type);
    if (category) byCategory[category] += count;
  }
  return { unread, byCategory };
}

/** Push the recipient's fresh badge counts to every device they're signed in on. */
async function emitCounts(userId) {
  try {
    emitToUser(userId, 'notification_count', await unreadSummary(userId));
  } catch (err) {
    logger.warn({ err, userId }, 'Failed to emit notification counts');
  }
}

/**
 * Fold the actor's display snapshot into the payload when the caller supplied
 * an actorId but not the from* fields. Keeping this here means callers never
 * have to remember the enrichment step, and there is exactly one place that
 * decides what an "actor" looks like on a notification.
 */
async function withActor(actorId, payload) {
  if (!actorId || payload?.fromUserId) return payload;
  return { ...payload, ...(await actorPayload(actorId)) };
}

/** Resolve the entity/group defaults a caller didn't supply. */
function resolveRefs({ type, entityType, entityId, groupTargetId, postId, conversationId, communityId }) {
  const resolvedEntityId = entityId ?? postId ?? conversationId ?? communityId ?? null;
  return {
    entityType: entityType ?? entityTypeOf(type),
    entityId:   resolvedEntityId,
    // The grouping target is not always the entity: post_commented stores the
    // comment id (so a tap can scroll to it) but groups by the post.
    groupKey:   buildGroupKey(type, groupTargetId ?? resolvedEntityId),
  };
}

/** Create one notification and push it to the recipient. */
async function pushUserNotification({
  userId, type, actorId = null, postId = null, communityId = null,
  conversationId = null, entityType = null, entityId = null,
  groupTargetId = null, payload = {},
}) {
  try {
    if (!isKnownType(type)) {
      logger.warn({ userId, type }, 'Refusing to create notification of unknown type');
      return null;
    }

    const refs = resolveRefs({
      type, entityType, entityId, groupTargetId, postId, conversationId, communityId,
    });

    const notif = await userNotifModel.createNotification({
      userId, type, actorId, postId, communityId, conversationId,
      payload: await withActor(actorId, payload), ...refs,
    });

    emitToUser(userId, 'notification', toNotificationDTO(notif));
    await emitCounts(userId);
    return notif;
  } catch (err) {
    logger.warn({ err, userId, type }, 'Failed to push user notification');
    return null;
  }
}

/** Create the same notification for an explicit list of recipients. */
async function pushToMany({ userIds, type, groupTargetId = null, ...rest }) {
  try {
    if (!isKnownType(type)) {
      logger.warn({ type }, 'Refusing to create notifications of unknown type');
      return [];
    }
    const recipients = [...new Set((userIds ?? []).filter(Boolean))];
    if (!recipients.length) return [];

    const refs = resolveRefs({ type, groupTargetId, ...rest });
    const rows = await userNotifModel.createBulkForUsers({
      userIds: recipients, type, ...rest, ...refs,
      payload: await withActor(rest.actorId, rest.payload ?? {}),
    });

    await emitToRecipients(rows);
    return rows;
  } catch (err) {
    logger.warn({ err, type }, 'Failed to push notifications to many');
    return [];
  }
}

/**
 * Fan one notification out to a community's members (optionally only to staff
 * via `roles`). Replaces the old createBulkNotifications, which wrote rows and
 * emitted nothing — community notifications had no realtime path at all.
 */
async function fanOutCommunityNotification({
  communityId, type, actorId = null, excludeUserId = null, postId = null,
  entityType = null, entityId = null, groupTargetId = null,
  payload = {}, roles = null,
}) {
  try {
    if (!isKnownType(type)) {
      logger.warn({ communityId, type }, 'Refusing to fan out unknown notification type');
      return [];
    }

    const refs = resolveRefs({
      type, entityType, entityId,
      // Community notifications group by community, so "3 new posts in Hiking"
      // collapses into a single row rather than one row per post.
      groupTargetId: groupTargetId ?? communityId,
      postId, communityId,
    });

    const rows = await userNotifModel.createBulkForCommunity({
      communityId, type, actorId, excludeUserId, postId, roles,
      payload: await withActor(actorId, payload), ...refs,
    });

    await emitToRecipients(rows);
    return rows;
  } catch (err) {
    logger.warn({ err, communityId, type }, 'Failed to fan out community notification');
    return [];
  }
}

/** Emit `notification` + fresh counts to each row's recipient, up to the cap. */
async function emitToRecipients(rows) {
  const capped = rows.slice(0, MAX_FANOUT_EMITS);
  if (rows.length > capped.length) {
    logger.info(
      { total: rows.length, emitted: capped.length },
      'Notification fan-out exceeded the emit cap; remaining recipients will poll'
    );
  }
  for (const row of capped) {
    emitToUser(row.user_id, 'notification', toNotificationDTO(row));
    await emitCounts(row.user_id);
  }
}

// ─── Chat ─────────────────────────────────────────────────────────────────────

/**
 * A self-contained snapshot of the conversation, embedded in every chat
 * notification payload so the client can open the chat screen with no extra
 * lookups. For a 1:1 the "peer" from the recipient's point of view is always
 * the sender; for a group it's the group itself.
 */
async function buildConversationCard(conversation, senderId) {
  const card = {
    conversationId: conversation.id,
    isGroup:        conversation.is_group,
    mode:           conversation.mode,
  };

  if (conversation.is_group) {
    return {
      ...card,
      groupName:        conversation.name,
      groupAvatarUrl:   conversation.avatar_url,
      groupAvatarColor: conversation.avatar_color,
      memberCount:      await messageModel.getGroupMemberCount(conversation.id),
    };
  }

  // Persona-aware: the sender's display name depends on the conversation mode.
  const { rows: [sender] } = await query(
    `SELECT id,
            ${personaExpr('display_name', '$2')} AS display_name,
            ${personaExpr('avatar_url', '$2')}   AS avatar_url,
            avatar_color
     FROM users u WHERE id = $1`,
    [senderId, conversation.mode]
  );

  return {
    ...card,
    peerUserId:      senderId,
    peerDisplayName: sender?.display_name ?? null,
    peerAvatarUrl:   sender?.avatar_url ?? null,
    peerAvatarColor: sender?.avatar_color ?? null,
  };
}

/** Short preview of a message, matching the placeholders the chat list uses. */
function messagePreview(message) {
  if (!message) return null;
  switch (message.message_type) {
    case 'image': return '📷 Photo';
    case 'video': return '🎥 Video';
    case 'voice': return '🎤 Voice message';
    default:
      return (message.content ?? '').slice(0, PREVIEW_LENGTH) || null;
  }
}

/**
 * Notify a conversation's participants of a new message.
 *
 * One row per (recipient, conversation), bumped rather than duplicated — a
 * notification per message would flood the inbox and drown every other type.
 * Muted participants and the sender are excluded inside the SQL.
 */
async function pushMessageNotification({ conversationId, senderId, message }) {
  try {
    const conversation = await messageModel.getConversationById(conversationId);
    if (!conversation) return [];

    const card = await buildConversationCard(conversation, senderId);
    const rows = await userNotifModel.upsertMessageNotification({
      conversationId,
      senderId,
      groupKey: buildGroupKey('message', conversationId),
      payload: {
        ...card,
        lastMessageId:   message?.id ?? null,
        lastMessageType: message?.message_type ?? 'text',
        preview:         messagePreview(message),
      },
    });

    await emitToRecipients(rows);
    return rows;
  } catch (err) {
    logger.warn({ err, conversationId }, 'Failed to push message notification');
    return [];
  }
}

/**
 * Notify chat participants of something that isn't a plain message — a meeting
 * proposal, an RSVP, a reaction, being added to a group.
 *
 * Wraps pushToMany with the conversation card so every chat notification can
 * open its conversation without a lookup, and excludes the actor.
 */
async function pushChatNotification({
  conversationId, type, actorId, userIds = null, entityId = null,
  groupTargetId = null, payload = {},
}) {
  try {
    // Omitting userIds means "everyone in the conversation".
    const candidates = userIds ?? await messageModel.getParticipants(conversationId);
    const recipients = (candidates ?? []).filter((uid) => uid && uid !== actorId);
    if (!recipients.length) return [];

    const conversation = await messageModel.getConversationById(conversationId);
    if (!conversation) return [];

    return pushToMany({
      userIds: recipients,
      type,
      actorId,
      conversationId,
      entityId,
      groupTargetId,
      payload: { ...(await buildConversationCard(conversation, actorId)), ...payload },
    });
  } catch (err) {
    logger.warn({ err, conversationId, type }, 'Failed to push chat notification');
    return [];
  }
}

/** Clear a conversation's inbox row once the user has opened and read it. */
async function clearConversationNotification(conversationId, userId) {
  try {
    const ids = await userNotifModel.markConversationRead(conversationId, userId);
    if (!ids.length) return;
    emitToUser(userId, 'notification_read', { ids, isRead: true });
    await emitCounts(userId);
  } catch (err) {
    logger.warn({ err, conversationId, userId }, 'Failed to clear conversation notification');
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

/** Standard payload about the actor who triggered the action. */
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

/**
 * Is there already an unread, recent notification with this group key from
 * this actor? Stops a like / unlike / re-like burst from spamming the target.
 */
async function hasPendingDuplicate({ userId, type, groupTargetId, actorId }) {
  return userNotifModel.hasPendingDuplicate({
    userId,
    groupKey: buildGroupKey(type, groupTargetId),
    actorId,
  });
}

module.exports = {
  pushUserNotification,
  pushToMany,
  fanOutCommunityNotification,
  pushMessageNotification,
  pushChatNotification,
  clearConversationNotification,
  actorPayload,
  hasPendingDuplicate,
  unreadSummary,
  emitCounts,
  toNotificationDTO,
  typesForCategory,
};
