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

// Send a message; verify participant and validate content
async function sendMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null, replyToMessageId = null }) {
  const allowed = await messageModel.isParticipant(conversationId, senderId);
  if (!allowed) clientError('Conversation not found', 404);

  if (messageType === 'text' && !content?.trim()) clientError('Message content is required');
  if (['image', 'video'].includes(messageType) && !mediaUrl) clientError('Media URL is required');
  if (content && content.length > 2000) clientError('Message is too long');

  const replyTo = await resolveReplyTarget(conversationId, replyToMessageId);

  const message = await messageModel.insertMessage(conversationId, senderId, {
    content: content?.trim() || null,
    messageType,
    mediaUrl,
    replyToMessageId: replyTo,
  });

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
};
