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
  if (!['friend', 'colleague'].includes(mode)) clientError('Invalid mode');

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
  if (!['friend', 'colleague'].includes(mode)) clientError('Invalid mode');
  return messageModel.listConversations(userId, mode);
}

// Fetch messages; verify the requester is a participant
async function getMessages(conversationId, userId, { limit, before }) {
  const allowed = await messageModel.isParticipant(conversationId, userId);
  if (!allowed) clientError('Conversation not found', 404);
  return messageModel.listMessages(conversationId, { limit, before });
}

// Send a message; verify participant and validate content
async function sendMessage(conversationId, senderId, { content, messageType = 'text', mediaUrl = null }) {
  const allowed = await messageModel.isParticipant(conversationId, senderId);
  if (!allowed) clientError('Conversation not found', 404);

  if (messageType === 'text' && !content?.trim()) clientError('Message content is required');
  if (['image', 'video'].includes(messageType) && !mediaUrl) clientError('Media URL is required');
  if (content && content.length > 2000) clientError('Message is too long');

  const message = await messageModel.insertMessage(conversationId, senderId, {
    content: content?.trim() || null,
    messageType,
    mediaUrl,
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
  if (!['friend', 'colleague'].includes(mode)) clientError('Invalid mode');
  return messageModel.totalUnread(userId, mode);
}

module.exports = {
  getOrCreateConversation,
  getConversations,
  getMessages,
  sendMessage,
  recallMessage,
  readMessages,
  getUnreadCount,
};
