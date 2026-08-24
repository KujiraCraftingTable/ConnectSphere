const messageModel = require('../models/messageModel');
const userModel    = require('../models/userModel');
const { emitToRoom, emitToUser } = require('../utils/realtime');

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Return existing conversation or create a new one between two users
async function getOrCreateConversation(userId, otherUserId, mode) {
  if (userId === otherUserId) clientError('Cannot start a conversation with yourself');
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');

  // Không mở được hội thoại giữa 2 user đã chặn nhau (chiều bất kỳ)
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

// A 'meeting' message's proposal fields must be present and starts_at must be
// a real, future timestamp — same validation shape as postService.createEventPost.
function validateMeetingProposal(meetingProposal) {
  if (!meetingProposal?.title?.trim()) clientError('Meeting title is required');
  if (!meetingProposal?.startsAt)      clientError('Meeting start time is required');

  const startsAt = new Date(meetingProposal.startsAt);
  if (isNaN(startsAt.getTime())) clientError('Invalid meeting start time');
  if (startsAt <= new Date())    clientError('Meeting start time must be in the future');

  return {
    title:    meetingProposal.title.trim(),
    location: meetingProposal.location?.trim() || null,
    startsAt: meetingProposal.startsAt,
    endsAt:   meetingProposal.endsAt || null,
  };
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
async function sendMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null, replyToMessageId = null, meetingProposal = null }) {
  const allowed = await messageModel.isParticipant(conversationId, senderId);
  if (!allowed) clientError('Conversation not found', 404);

  if (messageType === 'text' && !content?.trim()) clientError('Message content is required');
  if (['image', 'video'].includes(messageType) && !mediaUrl) clientError('Media URL is required');
  if (content && content.length > 2000) clientError('Message is too long');

  let validatedMeeting = null;
  if (messageType === 'meeting') validatedMeeting = validateMeetingProposal(meetingProposal);

  const replyTo = await resolveReplyTarget(conversationId, replyToMessageId);

  // messages.content_or_media requires content OR media_url — a 'meeting'
  // message has neither by default, so fall back to the proposal title as
  // the stored content (also gives a sensible "last message" preview).
  let message = await messageModel.insertMessage(conversationId, senderId, {
    content: content?.trim() || (validatedMeeting ? validatedMeeting.title : null),
    messageType,
    mediaUrl,
    replyToMessageId: replyTo,
  });

  if (validatedMeeting) {
    await messageModel.createMeetingProposal(message.id, validatedMeeting);
    // Insert-then-refetch (same pattern as reply preview) so the returned
    // row already carries the embedded proposal.
    message = await messageModel.getMessageById(message.id);
  }

  // Tin gửi qua REST cũng phải phát realtime như tin gửi qua socket
  emitToRoom(conversationId, 'new_message', message);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'new_message', message));

  return message;
}

// Thu hồi tin nhắn của chính mình; phát realtime cho cả 2 phía
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
}

// Unread badge count
async function getUnreadCount(userId, mode) {
  if (!['hobby', 'work'].includes(mode)) clientError('Invalid mode');
  return messageModel.totalUnread(userId, mode);
}

// ── Conversation settings ─────────────────────────────────────────────────────

// Settings snapshot: shared theme + caller's mute + other user info
async function getSettings(conversationId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  const settings = await messageModel.getSettings(conversationId, userId);
  if (!settings) clientError('Conversation not found', 404);
  return settings;
}

// Update shared settings (theme and/or the other person's nickname); broadcast to both
async function updateSettings(conversationId, userId, { theme, nickname }) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const participants = await messageModel.getParticipants(conversationId);
  const otherId = participants.find((uid) => uid !== userId);

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
    if (otherId) await messageModel.setNickname(conversationId, otherId, value);
  }

  const settings = await messageModel.getSettings(conversationId, userId);

  // Shared settings → notify both participants so their UI updates in realtime
  const payload = {
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

  const reactions = await messageModel.setReaction(messageId, userId, emoji);

  const payload = { conversation_id: conversationId, message_id: messageId, reactions };
  emitToRoom(conversationId, 'reaction_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'reaction_updated', payload));

  return reactions;
}

// Reschedule a meeting proposal — only the proposer may do this, and only
// while it's still active. Clears prior RSVPs (handled by the model call)
// since a response to the old time shouldn't carry over to the new one.
async function updateMeetingProposal(conversationId, messageId, userId, { title, location, startsAt, endsAt }) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const proposal = await resolveMeetingProposal(conversationId, messageId);
  if (userId !== proposal.sender_id) clientError('Only the proposer can reschedule this meeting', 403);
  if (proposal.status !== 'active') clientError('Cannot reschedule a cancelled meeting', 409);

  const validated = validateMeetingProposal({ title, location, startsAt, endsAt });
  await messageModel.updateMeetingProposal(proposal.id, validated);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_proposal_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_proposal_updated', payload));

  return message.meeting_proposal;
}

// Cancel a meeting proposal — only the proposer, and only while active.
async function cancelMeetingProposal(conversationId, messageId, userId) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);

  const proposal = await resolveMeetingProposal(conversationId, messageId);
  if (userId !== proposal.sender_id) clientError('Only the proposer can cancel this meeting', 403);
  if (proposal.status !== 'active') clientError('Meeting is already cancelled', 409);

  await messageModel.cancelMeetingProposal(proposal.id);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_proposal_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_proposal_updated', payload));

  return message.meeting_proposal;
}

// RSVP to a meeting proposal — any participant (including the proposer),
// while it's still active. Mirrors reactToMessage's shape exactly.
async function respondToMeeting(conversationId, messageId, userId, status) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  if (!messageModel.ALLOWED_MEETING_RSVP_STATUS.includes(status)) clientError('Status must be going, maybe, or not_going');

  const proposal = await resolveMeetingProposal(conversationId, messageId);
  if (proposal.status !== 'active') clientError('Cannot respond to a cancelled meeting', 409);

  await messageModel.setMeetingRsvp(proposal.id, userId, status);

  const message = await messageModel.getMessageById(messageId);
  const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };
  emitToRoom(conversationId, 'meeting_response_updated', payload);
  const participants = await messageModel.getParticipants(conversationId).catch(() => []);
  participants.forEach((uid) => emitToUser(uid, 'meeting_response_updated', payload));

  return message.meeting_proposal;
}

module.exports = {
  getOrCreateConversation,
  getConversations,
  getMessages,
  sendMessage,
  recallMessage,
  readMessages,
  getUnreadCount,
  getSettings,
  updateSettings,
  setMute,
  getMedia,
  searchMessages,
  clearConversation,
  reactToMessage,
  updateMeetingProposal,
  cancelMeetingProposal,
  respondToMeeting,
};
