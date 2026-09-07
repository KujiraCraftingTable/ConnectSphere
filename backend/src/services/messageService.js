const messageModel = require('../models/messageModel');
const userModel    = require('../models/userModel');
const { emitToRoom, emitToUser } = require('../utils/realtime');
const notifyService = require('./userNotifyService');
const logger = require('../utils/logger');

/**
 * Fire-and-forget a chat notification. Chat events must never block or fail
 * the action that produced them, so the promise is deliberately not awaited
 * and every failure is logged rather than propagated.
 */
function notifyChat(args) {
  notifyService.pushChatNotification(args)
    .catch((err) => logger.warn({ err, type: args.type }, 'chat notification failed'));
}

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Hard cap on group size, enforced on both create and add-member
const GROUP_MEMBER_CAP = 100;
const DEFAULT_GROUP_NAME = 'New group';

// Return existing conversation or create a new one between two users
async function getOrCreateConversation(userId, otherUserId, mode) {
  if (userId === otherUserId) clientError('Cannot start a conversation with yourself');
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');

  // Cannot open a conversation between two users who have blocked each other (either direction)
  if (await userModel.isBlockedEitherWay(userId, otherUserId)) {
    clientError('Cannot message this user', 403);
  }

  const existing = await messageModel.findConversation(userId, otherUserId, mode);
  if (existing) return existing;

  return messageModel.createConversation(userId, otherUserId, mode);
}

// List conversations for a user
async function getConversations(userId, mode) {
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');
  return messageModel.listConversations(userId, mode);
}

// Create a new group conversation. Validates the 100-member cap, distinct
// member ids (none equal to the creator), a valid mode, and a name (trimmed,
// capped to the column length, defaulting to "New group" when omitted).
async function createGroupConversation(creatorId, memberIds, mode, name) {
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');
  if (!Array.isArray(memberIds) || memberIds.length === 0) {
    clientError('At least one member is required');
  }

  const uniqueMemberIds = [...new Set(memberIds)];
  if (uniqueMemberIds.length !== memberIds.length) clientError('Duplicate member ids are not allowed');
  if (uniqueMemberIds.includes(creatorId)) clientError('Creator should not be listed in member_ids');
  if (uniqueMemberIds.length + 1 > GROUP_MEMBER_CAP) {
    clientError(`A group cannot have more than ${GROUP_MEMBER_CAP} members`);
  }

  let groupName = DEFAULT_GROUP_NAME;
  if (name !== undefined && name !== null) {
    if (typeof name !== 'string') clientError('Invalid group name');
    const trimmed = name.trim();
    if (trimmed) groupName = trimmed.slice(0, 100);
  }

  return messageModel.createGroupConversation(creatorId, uniqueMemberIds, mode, groupName);
}

// Fetch messages; verify the requester is a participant
async function getMessages(conversationId, userId, { limit, before }) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.listMessages(conversationId, userId, { limit, before });
}

// A reply target must exist, belong to the same conversation, and not be
// itself (guards against a malformed/self-referencing quote).
async function resolveReplyTarget(conversationId, replyToMessageId) {
  if (!replyToMessageId) return null;
  const target = await messageModel.getMessageBasic(replyToMessageId);
  if (!target || target.conversation_id !== conversationId) {
    clientError('Message being replied to was not found in this conversation');
  }
  return replyToMessageId;
}

// Reminder lead-time presets — mirrors 020_meeting_reminders.sql's CHECK
// constraint on reminder_offset exactly (keep both lists in sync).
const ALLOWED_REMINDER_OFFSETS = ['on_day', '1_day_before', '2_days_before', '1_week_before'];
const REMINDER_OFFSET_DAYS = { on_day: 0, '1_day_before': 1, '2_days_before': 2, '1_week_before': 7 };
const DEFAULT_REMINDER_OFFSET = '1_day_before';

// Server-side fallback for reminderAt when a caller doesn't send one (e.g. a
// not-yet-updated client that predates the reminder feature — reminder_at is
// NOT NULL, so *something* valid always has to land in the column). Computes
// a UTC 07:00 instant N days before startsAt. This is intentionally a rough
// stand-in, not a real "7am local" — the schema tracks no per-user timezone
// (see 020_meeting_reminders.sql), so the iOS composer is expected to
// compute the precise device-local instant itself and send reminderAt
// explicitly once Phase 3 ships.
function defaultReminderAt(startsAt, offset) {
  const days = REMINDER_OFFSET_DAYS[offset] ?? REMINDER_OFFSET_DAYS[DEFAULT_REMINDER_OFFSET];
  const d = new Date(startsAt);
  d.setUTCDate(d.getUTCDate() - days);
  d.setUTCHours(7, 0, 0, 0);
  return d.toISOString();
}

// A 'meeting' message's proposal fields must be present and starts_at must be
// a real, future timestamp — same validation shape as postService.createEventPost.
// endsAt is optional, but when present it must parse and must fall after
// startsAt (guards against a raw Postgres error / a proposal that "ends"
// before it "starts"). reminderOffset must be one of the 4 lead-time
// presets when given (defaults to '1_day_before'); reminderAt must parse
// when given, else is computed via defaultReminderAt so the caller never
// has to special-case a legacy client that doesn't send it.
//
// Single shared validator — called from both the REST path (sendMessage,
// updateMeetingProposal below) and, via module.exports, index.js's socket
// handlers (send_message, update_meeting_proposal) — so title/time/reminder
// validation only lives in one place.
function validateMeetingProposal(meetingProposal) {
  if (!meetingProposal?.title?.trim()) clientError('Meeting title is required');
  if (!meetingProposal?.startsAt)      clientError('Meeting start time is required');

  const startsAt = new Date(meetingProposal.startsAt);
  if (isNaN(startsAt.getTime())) clientError('Invalid meeting start time');
  if (startsAt <= new Date())    clientError('Meeting start time must be in the future');

  if (meetingProposal.endsAt) {
    const endsAt = new Date(meetingProposal.endsAt);
    if (isNaN(endsAt.getTime())) clientError('Invalid meeting end time');
    if (endsAt <= startsAt)      clientError('Meeting end time must be after the start time');
  }

  let reminderOffset = DEFAULT_REMINDER_OFFSET;
  if (meetingProposal.reminderOffset !== undefined && meetingProposal.reminderOffset !== null) {
    if (!ALLOWED_REMINDER_OFFSETS.includes(meetingProposal.reminderOffset)) {
      clientError('Invalid reminder offset');
    }
    reminderOffset = meetingProposal.reminderOffset;
  }

  let reminderAt = meetingProposal.reminderAt;
  if (reminderAt !== undefined && reminderAt !== null && reminderAt !== '') {
    const parsedReminderAt = new Date(reminderAt);
    if (isNaN(parsedReminderAt.getTime())) clientError('Invalid reminder time');
    reminderAt = parsedReminderAt.toISOString();
  } else {
    reminderAt = defaultReminderAt(meetingProposal.startsAt, reminderOffset);
  }

  return {
    title:    meetingProposal.title.trim(),
    location: meetingProposal.location?.trim() || null,
    startsAt: meetingProposal.startsAt,
    endsAt:   meetingProposal.endsAt || null,
    reminderOffset,
    reminderAt,
  };
}

// Ensures the two sides of a conversation haven't blocked each other (either
// direction) — shared by any action that requires cooperation/visibility to
// the other party (sending a message, reacting, RSVP, reschedule, cancel).
// NOT used for recallMessage — recalling your own message doesn't need the
// other side's consent.
// Blocking within a group is a WARNING only, it does not stop sending messages
// (product decision) — this guard lets every call site below automatically
// skip enforcement for groups (>2 participants) without touching each one
// individually. 1:1 behavior is unchanged 100%.
async function assertNotBlockedInConversation(conversationId, userId) {
  const participantIds = await messageModel.getParticipants(conversationId);
  if (participantIds.length > 2) return;
  const otherId = participantIds.find((uid) => uid !== userId);
  if (otherId && await userModel.isBlockedEitherWay(userId, otherId)) {
    clientError('Cannot message this user', 403);
  }
}

// A meeting-related action is addressed by messageId; resolve it to its
// proposal + conversation/sender, 404ing if the message isn't a meeting
// proposal in this conversation. Mirrors resolveReplyTarget's "verify target
// belongs to this conversation" pattern.
async function resolveMeetingProposal(conversationId, messageId) {
  const proposal = await messageModel.getProposalByMessageId(messageId);
  if (!proposal || proposal.conversation_id !== conversationId || proposal.message_type !== 'meeting' || !proposal.id) {
    clientError('Meeting proposal not found', 404);
  }
  return proposal;
}

// Send a message; verify participant and validate content
async function sendMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null, replyToMessageId = null, meetingProposal = null, voiceDurationSeconds = null, voiceWaveform = null }) {
  const allowed = await messageModel.isParticipant(conversationId, senderId);
  if (!allowed) clientError('Conversation not found', 404);

  if (messageType === 'text' && !content?.trim()) clientError('Message content is required');
  if (['image', 'video', 'voice'].includes(messageType) && !mediaUrl) clientError('Media URL is required');
  if (content && content.length > 2000) clientError('Message is too long');

  let validatedMeeting = null;
  if (messageType === 'meeting') validatedMeeting = validateMeetingProposal(meetingProposal);

  const replyTo = await resolveReplyTarget(conversationId, replyToMessageId);

  // Don't allow sending a message if the two sides have blocked each other (either direction) — blocking today
  // only stopped *opening* a new conversation; this closes the gap for an
  // already-open one. Mirrors the exact check in getOrCreateConversation.
  await assertNotBlockedInConversation(conversationId, senderId);

  // messages.content_or_media requires content OR media_url — a 'meeting'
  // message has neither by default, so fall back to the proposal title as
  // the stored content (also gives a sensible "last message" preview).
  let message = await messageModel.insertMessage(conversationId, senderId, {
    content: content?.trim() || (validatedMeeting ? validatedMeeting.title : null),
    messageType,
    mediaUrl,
    replyToMessageId: replyTo,
    voiceDurationSeconds,
    voiceWaveform,
  });

  if (validatedMeeting) {
    await messageModel.createMeetingProposal(message.id, validatedMeeting);
    // Insert-then-refetch (same pattern as reply preview) so the returned
    // row already carries the embedded proposal.
    message = await messageModel.getMessageById(message.id);
  }

  // A message sent via REST must also be broadcast realtime, same as one sent via socket
  emitToRoom(conversationId, 'new_message', message);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'new_message', message));

  // Persist an inbox notification so the message is still discoverable when
  // the recipient was offline. Collapsed to one row per conversation, and
  // fire-and-forget so it can never delay or fail the send.
  notifyNewMessage(conversationId, senderId, message);

  return message;
}

/**
 * Raise the inbox notification for a newly sent message.
 *
 * Shared by both send paths — the REST service above and the `send_message`
 * socket handler in index.js — because they insert messages independently.
 * The unique index makes a double-insert impossible, so the worst a double
 * call could do is double-count; callers must invoke this exactly once.
 *
 * A meeting proposal raises its own dedicated notification rather than the
 * collapsed "new message" row: it carries the proposal details, and routing it
 * through both would notify twice for one action.
 */
function notifyNewMessage(conversationId, senderId, message) {
  if (message?.message_type === 'meeting' && message.meeting_proposal) {
    const proposal = message.meeting_proposal;
    notifyChat({
      conversationId,
      type:     'meeting_proposed',
      actorId:  senderId,
      entityId: proposal.id,
      payload:  {
        messageId:  message.id,
        proposalId: proposal.id,
        title:      proposal.title,
        startsAt:   proposal.starts_at,
        endsAt:     proposal.ends_at,
        location:   proposal.location,
      },
    });
    return;
  }

  notifyService.pushMessageNotification({ conversationId, senderId, message })
    .catch((err) => logger.warn({ err, conversationId }, 'message notification failed'));
}

// Recall a message of your own; broadcast realtime to both sides
async function recallMessage(conversationId, messageId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const recalled = await messageModel.recallMessage(messageId, conversationId, userId);
  if (!recalled) clientError('Message not found or not yours', 404);

  const payload = { conversation_id: conversationId, message_id: messageId };
  emitToRoom(conversationId, 'message_deleted', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'message_deleted', payload));
}

// Mark messages as read and update last_read_at
async function readMessages(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  await messageModel.markRead(conversationId, userId);
  // Opening the chat clears its inbox row, so the notification badge can never
  // disagree with what the chat screen shows.
  await notifyService.clearConversationNotification(conversationId, userId);
}

// Mark one message delivered (live path, called from the recipient's socket
// the instant it receives 'new_message' for someone else's message). Mirrors
// readMessages's participant-gate shape exactly. Returns the updated row (or
// null if nothing was upgraded — e.g. already delivered/read, or not found).
async function deliverMessage(conversationId, messageId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.markMessageDelivered(messageId, userId);
}

// Mark every outstanding 'sent' message in a conversation delivered (REST
// catch-up path, called when the recipient reconnects/opens the chat after
// being offline). Mirrors readMessages's participant-gate shape exactly.
// Returns one row per message actually updated, for the caller to broadcast.
async function deliverConversation(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.markConversationDelivered(conversationId, userId);
}

// Unread badge count
async function getUnreadCount(userId, mode) {
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');
  return messageModel.totalUnread(userId, mode);
}

// ── Conversation settings ─────────────────────────────────────────────────────

// Settings snapshot: dispatches to the 1:1 shape (shared theme + caller's
// mute + other user info) or the group shape (name/avatar/theme + members),
// based on the conversation's is_group flag.
async function getSettings(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation) clientError('Conversation not found', 404);

  const settings = conversation.is_group
    ? await messageModel.getGroupSettings(conversationId, userId)
    : await messageModel.getSettings1to1(conversationId, userId);
  if (!settings) clientError('Conversation not found', 404);
  return settings;
}

// Update shared settings (theme and/or a nickname); broadcast to all participants.
// For 1:1, nickname behavior is completely unchanged: it always targets "the
// other person" (targetUserId is ignored). For groups, targetUserId is
// required — a group has no single "other person," so the nickname's target
// member must be named explicitly.
async function updateSettings(conversationId, userId, { theme, nickname, targetUserId } = {}) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation) clientError('Conversation not found', 404);

  const participants = await messageModel.getParticipants(conversationId);

  if (theme !== undefined) {
    if (theme !== null && (typeof theme !== 'string' || theme.length > 20)) {
      clientError('Invalid theme');
    }
    await messageModel.updateTheme(conversationId, theme || null);
  }

  if (nickname !== undefined) {
    let value = null;
    if (nickname !== null) {
      if (typeof nickname !== 'string') clientError('Invalid nickname');
      value = nickname.trim().slice(0, 50) || null;
    }

    if (conversation.is_group) {
      if (!targetUserId) clientError('target_user_id is required to set a nickname in a group');
      if (!participants.includes(targetUserId)) clientError('User is not a member of this group', 404);
      if (value === null) {
        await messageModel.deleteGroupNickname(conversationId, userId, targetUserId);
      } else {
        await messageModel.setGroupNickname(conversationId, userId, targetUserId, value);
      }
    } else {
      const otherId = participants.find((uid) => uid !== userId);
      if (otherId) await messageModel.setNickname(conversationId, otherId, value);
    }
  }

  const settings = conversation.is_group
    ? await messageModel.getGroupSettings(conversationId, userId)
    : await messageModel.getSettings1to1(conversationId, userId);

  // Shared settings → notify all participants so their UI updates in realtime
  const payload = conversation.is_group
    ? { conversation_id: conversationId, theme: settings.theme }
    : {
        conversation_id: conversationId,
        theme: settings.theme,
        nickname_target_id: settings.other_user_id,
        nickname: settings.other_user_nickname,
      };
  participants.forEach((uid) => emitToUser(uid, 'conversation_settings_updated', payload));

  return settings;
}

// Set the caller's mute preference (personal; no broadcast).
//   minutes: null → unmute, negative → until turned back on, N>0 → N minutes (cap 30 days)
async function setMute(conversationId, userId, minutes) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  let value = null;
  if (minutes !== null && minutes !== undefined) {
    const n = parseInt(minutes, 10);
    if (Number.isNaN(n)) clientError('Invalid mute duration');
    value = n < 0 ? -1 : Math.min(n, 43200);
  }
  const mutedUntil = await messageModel.setMute(conversationId, userId, value);
  return { muted_until: mutedUntil };
}

// Media gallery for the conversation
async function getMedia(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.listMedia(conversationId, userId);
}

// Search text messages by keyword
async function searchMessages(conversationId, userId, term) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  const q = (term || '').trim();
  if (!q) return [];
  return messageModel.searchMessages(conversationId, userId, q);
}

// Clear the conversation on the caller's side only
async function clearConversation(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  await messageModel.clearConversation(conversationId, userId);
}

// React to a message — toggle off if re-tapping the same emoji, else set/replace.
// Broadcasts the message's fresh reaction summary to both participants.
async function reactToMessage(conversationId, messageId, userId, emoji) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  if (!messageModel.ALLOWED_REACTION_EMOJI.includes(emoji)) clientError('Unsupported emoji');

  const target = await messageModel.getMessageBasic(messageId);
  if (!target || target.conversation_id !== conversationId) clientError('Message not found', 404);

  await assertNotBlockedInConversation(conversationId, userId);

  const reactions = await messageModel.setReaction(messageId, userId, emoji);

  const payload = { conversation_id: conversationId, message_id: messageId, reactions };
  emitToRoom(conversationId, 'reaction_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'reaction_updated', payload));

  // Only the message's author cares that their message was reacted to.
  notifyChat({
    conversationId,
    type:     'message_reaction',
    actorId:  userId,
    userIds:  [target.sender_id],
    entityId: messageId,
    payload:  { messageId, emoji },
  });

  return reactions;
}

// Reschedule a meeting proposal — only the proposer may do this, and only
// while it's still active. Clears prior RSVPs (handled by the model call)
// since a response to the old time shouldn't carry over to the new one.
async function updateMeetingProposal(conversationId, messageId, userId, { title, location, startsAt, endsAt, reminderOffset, reminderAt }) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const proposal = await resolveMeetingProposal(conversationId, messageId);
  if (userId !== proposal.sender_id) clientError('Only the proposer can reschedule this meeting', 403);
  if (proposal.status !== 'active') clientError('Cannot reschedule a cancelled meeting', 409);
  await assertNotBlockedInConversation(conversationId, userId);

  const validated = validateMeetingProposal({ title, location, startsAt, endsAt, reminderOffset, reminderAt });
  await messageModel.updateMeetingProposal(proposal.id, validated);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_proposal_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_proposal_updated', payload));

  notifyChat({
    conversationId,
    type:     'meeting_updated',
    actorId:  userId,
    userIds:  participants,
    entityId: proposal.id,
    payload:  {
      messageId,
      proposalId: proposal.id,
      changeKind: 'rescheduled',
      title:      validated.title,
      startsAt:   validated.startsAt,
    },
  });

  return message.meeting_proposal;
}

// Cancel a meeting proposal — only the proposer, and only while active.
async function cancelMeetingProposal(conversationId, messageId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const proposal = await resolveMeetingProposal(conversationId, messageId);
  if (userId !== proposal.sender_id) clientError('Only the proposer can cancel this meeting', 403);
  if (proposal.status !== 'active') clientError('Meeting is already cancelled', 409);
  await assertNotBlockedInConversation(conversationId, userId);

  await messageModel.cancelMeetingProposal(proposal.id);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_proposal_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_proposal_updated', payload));

  notifyChat({
    conversationId,
    type:     'meeting_updated',
    actorId:  userId,
    userIds:  participants,
    entityId: proposal.id,
    payload:  {
      messageId,
      proposalId: proposal.id,
      changeKind: 'cancelled',
      title:      message.meeting_proposal?.title ?? null,
    },
  });

  return message.meeting_proposal;
}

// RSVP to a meeting proposal — any participant (including the proposer),
// while it's still active, and ONLY for a group conversation. RSVP makes no
// sense in a 1:1: the two people already coordinate by talking, so a 1:1
// proposal is reminder-only (Phase 3/4 iOS won't even show RSVP UI there) —
// this is the defensive backend guard for that, using the canonical
// conversations.is_group column (NOT the participantIds.length > 2
// heuristic assertNotBlockedInConversation uses for its own unrelated
// "groups are alert-only for blocking" purpose).
async function respondToMeeting(conversationId, messageId, userId, status) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  if (!messageModel.ALLOWED_MEETING_RSVP_STATUS.includes(status)) clientError('Status must be going, maybe, or not_going');

  const proposal = await resolveMeetingProposal(conversationId, messageId);

  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation || !conversation.is_group) {
    clientError('RSVP is not applicable to a 1:1 meeting');
  }

  await assertNotBlockedInConversation(conversationId, userId);

  // The "still active" check is enforced atomically inside the write itself
  // (messageModel.setMeetingRsvp guards the INSERT with a WHERE EXISTS on
  // status = 'active') rather than as a separate check-then-act step here —
  // closes the race where the proposal is cancelled/rescheduled between a
  // check and the RSVP write landing.
  const rsvp = await messageModel.setMeetingRsvp(proposal.id, userId, status);
  if (!rsvp) clientError('Cannot respond to a cancelled meeting', 409);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_response_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_response_updated', payload));

  // Only the proposer needs to hear about an RSVP; the rest of the group sees
  // it live in the proposal card.
  notifyChat({
    conversationId,
    type:     'meeting_rsvp',
    actorId:  userId,
    userIds:  [proposal.sender_id],
    entityId: proposal.id,
    payload:  { messageId, proposalId: proposal.id, status },
  });

  return message.meeting_proposal;
}

// ── Group block acknowledgement (alert-only in groups) ──────────────────────

// Whether the caller should see the "people you've blocked are in this group"
// alert. Only meaningful for groups — 1:1 uses the hard block above, unchanged.
async function getBlockAlertState(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation || !conversation.is_group) return { shouldAlert: false };

  const blockedIds = await messageModel.getBlockedIdsInConversation(conversationId, userId);
  if (blockedIds.length === 0) return { shouldAlert: false };

  const ack = await messageModel.getBlockAck(conversationId, userId);
  const currentSnapshot = blockedIds.slice().sort().join(',');
  const shouldAlert = !ack || ack.acked_blocked_ids !== currentSnapshot;

  return shouldAlert ? { shouldAlert: true, blockedUserIds: blockedIds } : { shouldAlert: false };
}

// Record that the caller has acknowledged the CURRENT blocked-set for this
// group (computed fresh, not trusted from the client) — re-alerts only once
// the set actually changes (e.g. a newly-added member is also blocked).
async function acknowledgeBlockAlert(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const blockedIds = await messageModel.getBlockedIdsInConversation(conversationId, userId);
  await messageModel.setBlockAck(conversationId, userId, blockedIds);
  return { acked: true };
}

// ── Group management (owner-gated except leaveGroup) ────────────────────────

// Shared owner-only gate: participant already verified by the caller.
async function requireGroupOwner(conversationId, userId) {
  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation || !conversation.is_group) clientError('Conversation not found', 404);

  const role = await messageModel.getParticipantRole(conversationId, userId);
  if (!role) clientError('Conversation not found', 404);
  if (role !== 'owner') clientError('Only the group owner can do this', 403);

  return conversation;
}

// Fetch the fresh group settings and broadcast 'group_updated' to every
// participant — shared tail end for rename/re-photo/promote.
async function broadcastGroupUpdated(conversationId, extra = {}) {
  const settings = await messageModel.getGroupSettings(conversationId);
  const payload = {
    conversation_id: conversationId,
    name: settings.name,
    avatar_url: settings.avatar_url,
    avatar_color: settings.avatar_color,
    ...extra,
  };
  emitToRoom(conversationId, 'group_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'group_updated', payload));
  return settings;
}

// Add members to a group — owner-only. Re-checks the 100-cap against
// current + new count (members already present are silently skipped rather
// than erroring, so retrying an add is idempotent).
async function addMembers(conversationId, actorId, newMemberIds) {
  const allowed = await messageModel.isParticipant(conversationId, actorId);
  if (!allowed) clientError('Conversation not found', 404);
  await requireGroupOwner(conversationId, actorId);

  if (!Array.isArray(newMemberIds) || newMemberIds.length === 0) {
    clientError('At least one member is required');
  }
  const uniqueNew = [...new Set(newMemberIds)];

  const currentMembers = await messageModel.getParticipants(conversationId);
  const toAdd = uniqueNew.filter((uid) => !currentMembers.includes(uid));

  if (toAdd.length && currentMembers.length + toAdd.length > GROUP_MEMBER_CAP) {
    clientError(`A group cannot have more than ${GROUP_MEMBER_CAP} members`);
  }

  if (toAdd.length) await messageModel.addParticipants(conversationId, toAdd);

  const settings = await messageModel.getGroupSettings(conversationId);
  const payload = { conversation_id: conversationId, added_user_ids: toAdd, members: settings.members };
  emitToRoom(conversationId, 'member_added', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'member_added', payload));

  // Only the people just added need telling — the rest see it in the thread.
  if (toAdd.length) {
    notifyChat({
      conversationId,
      type:    'group_added',
      actorId,
      userIds: toAdd,
    });
  }

  return settings;
}

// Remove a member from a group — owner-only. Removing yourself goes through
// leaveGroup instead (it has the auto-promote-on-leave behavior).
async function removeMember(conversationId, actorId, targetId) {
  const allowed = await messageModel.isParticipant(conversationId, actorId);
  if (!allowed) clientError('Conversation not found', 404);
  await requireGroupOwner(conversationId, actorId);
  if (targetId === actorId) clientError('Use leave instead of removing yourself');

  const isMember = await messageModel.isParticipant(conversationId, targetId);
  if (!isMember) clientError('User is not a member of this group', 404);

  await messageModel.removeParticipant(conversationId, targetId);

  const payload = { conversation_id: conversationId, removed_user_id: targetId };
  const remaining = await messageModel.getParticipants(conversationId).catch(() => []);
  remaining.forEach((uid) => emitToUser(uid, 'member_removed', payload));
  // Targeted event so the removed user's client navigates out even though
  // they're no longer a participant (and so won't receive the room broadcast).
  emitToUser(targetId, 'removed_from_conversation', payload);
  // Persisted counterpart, so they still learn about it if they were offline.
  // Routes to the chat list rather than the conversation they can't open.
  notifyChat({
    conversationId,
    type:    'group_removed',
    actorId,
    userIds: [targetId],
  });

  return { removed: true };
}

// Rename a group — owner-only.
async function renameGroup(conversationId, actorId, name) {
  const allowed = await messageModel.isParticipant(conversationId, actorId);
  if (!allowed) clientError('Conversation not found', 404);
  await requireGroupOwner(conversationId, actorId);

  if (typeof name !== 'string' || !name.trim()) clientError('Group name is required');
  await messageModel.updateGroupInfo(conversationId, { name: name.trim().slice(0, 100) });

  return broadcastGroupUpdated(conversationId);
}

// Update a group's photo — owner-only. Accepts avatarUrl and/or avatarColor.
async function updateGroupAvatar(conversationId, actorId, { avatarUrl, avatarColor } = {}) {
  const allowed = await messageModel.isParticipant(conversationId, actorId);
  if (!allowed) clientError('Conversation not found', 404);
  await requireGroupOwner(conversationId, actorId);

  if (avatarUrl === undefined && avatarColor === undefined) {
    clientError('avatar_url or avatar_color is required');
  }
  await messageModel.updateGroupInfo(conversationId, { avatarUrl, avatarColor });

  return broadcastGroupUpdated(conversationId);
}

// Promote another member to owner — owner-only. Uses the transactional model
// swap so the group is never left with zero (or two) owners mid-request.
async function promoteOwner(conversationId, actorId, targetId) {
  const allowed = await messageModel.isParticipant(conversationId, actorId);
  if (!allowed) clientError('Conversation not found', 404);
  await requireGroupOwner(conversationId, actorId);

  if (targetId === actorId) clientError('You are already the owner');
  const isMember = await messageModel.isParticipant(conversationId, targetId);
  if (!isMember) clientError('User is not a member of this group', 404);

  await messageModel.transferOwnership(conversationId, actorId, targetId);

  return broadcastGroupUpdated(conversationId, { new_owner_id: targetId });
}

// Leave a group — any member. If the leaver is the sole owner and other
// members remain, ownership auto-transfers to the earliest-joined remaining
// member first (no explicit "promote before you can leave" step required).
// If the leaver is the last member, the conversation is simply left empty —
// no special cleanup needed for v1.
async function leaveGroup(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const conversation = await messageModel.getConversationById(conversationId);
  if (!conversation || !conversation.is_group) clientError('Conversation not found', 404);

  const role = await messageModel.getParticipantRole(conversationId, userId);
  const members = await messageModel.listParticipantsOrderedByJoin(conversationId);
  const others = members.filter((m) => m.user_id !== userId);

  if (role === 'owner' && others.length > 0) {
    await messageModel.transferOwnership(conversationId, userId, others[0].user_id);
  }

  await messageModel.removeParticipant(conversationId, userId);

  const payload = { conversation_id: conversationId, removed_user_id: userId };
  const remaining = await messageModel.getParticipants(conversationId).catch(() => []);
  remaining.forEach((uid) => emitToUser(uid, 'member_removed', payload));

  return { left: true };
}

// ── Message pins ────────────────────────────────────────────────────────────

// Pin a message — any participant may pin. Validates the message belongs to
// this conversation and that expiresAt (if given) is a real, future
// timestamp. The 10-pin cap is enforced atomically inside
// messageModel.pinMessage's guarded INSERT; a null return means the cap was
// already hit, which this maps to a clear 400.
async function pinMessage(conversationId, messageId, userId, expiresAt) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const target = await messageModel.getMessageBasic(messageId);
  if (!target || target.conversation_id !== conversationId) clientError('Message not found', 404);

  let validatedExpiresAt = null;
  if (expiresAt !== undefined && expiresAt !== null) {
    const parsed = new Date(expiresAt);
    if (isNaN(parsed.getTime())) clientError('Invalid expires_at');
    if (parsed <= new Date()) clientError('expires_at must be in the future');
    validatedExpiresAt = expiresAt;
  }

  const pin = await messageModel.pinMessage(conversationId, messageId, userId, validatedExpiresAt);
  if (!pin) clientError(`This conversation already has ${messageModel.MAX_PINS_PER_CONVERSATION} pinned messages`);

  const pins = await messageModel.listPins(conversationId);
  const payload = { conversation_id: conversationId, message_id: messageId, pins };
  emitToRoom(conversationId, 'pin_added', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'pin_added', payload));

  return pin;
}

// Unpin a message — any participant may unpin (low-friction, matches
// reactions' any-participant behavior), not just whoever pinned it.
async function unpinMessage(conversationId, messageId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const unpinned = await messageModel.unpinMessage(conversationId, messageId);
  if (!unpinned) clientError('Pin not found', 404);

  const payload = { conversation_id: conversationId, message_id: messageId };
  emitToRoom(conversationId, 'pin_removed', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'pin_removed', payload));

  return { unpinned: true };
}

// List a conversation's pins, newest-pinned first.
async function listPins(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.listPins(conversationId);
}

module.exports = {
  notifyNewMessage,
  getOrCreateConversation,
  getConversations,
  createGroupConversation,
  getMessages,
  sendMessage,
  recallMessage,
  readMessages,
  deliverMessage,
  deliverConversation,
  getUnreadCount,
  getSettings,
  updateSettings,
  setMute,
  getMedia,
  searchMessages,
  clearConversation,
  reactToMessage,
  validateMeetingProposal,
  updateMeetingProposal,
  cancelMeetingProposal,
  respondToMeeting,
  assertNotBlockedInConversation,
  getBlockAlertState,
  acknowledgeBlockAlert,
  addMembers,
  removeMember,
  renameGroup,
  updateGroupAvatar,
  promoteOwner,
  leaveGroup,
  pinMessage,
  unpinMessage,
  listPins,
};
