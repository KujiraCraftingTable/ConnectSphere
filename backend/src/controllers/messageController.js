const messageService = require('../services/messageService');

// POST /api/messages/conversations
async function openConversation(req, res, next) {
  try {
    const { other_user_id, mode } = req.body;
    if (!other_user_id || !mode) {
      return res.status(400).json({ status: 'error', code: 400, message: 'other_user_id and mode are required' });
    }
    const conversation = await messageService.getOrCreateConversation(
      req.userId, other_user_id, mode
    );
    res.status(200).json({ data: conversation });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/conversations?mode=friend
async function listConversations(req, res, next) {
  try {
    const { mode } = req.query;
    if (!mode) return res.status(400).json({ status: 'error', code: 400, message: 'mode is required' });
    const conversations = await messageService.getConversations(req.userId, mode);
    res.json({ data: conversations });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/conversations/:id/messages?limit=30&before=<iso-timestamp>
async function listMessages(req, res, next) {
  try {
    const { limit = '30', before = null } = req.query;
    const messages = await messageService.getMessages(
      req.params.id,
      req.userId,
      { limit: parseInt(limit, 10), before }
    );
    res.json({ data: messages });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/messages
async function sendMessage(req, res, next) {
  try {
    const { content, message_type = 'text', media_url = null } = req.body;
    const message = await messageService.sendMessage(
      req.params.id,
      req.userId,
      { content, messageType: message_type, mediaUrl: media_url }
    );
    res.status(201).json({ data: message });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/messages/conversations/:id/messages/:messageId — thu hồi tin của mình
async function recallMessage(req, res, next) {
  try {
    await messageService.recallMessage(req.params.id, req.params.messageId, req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

// PUT /api/messages/conversations/:id/read
async function markRead(req, res, next) {
  try {
    await messageService.readMessages(req.params.id, req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/unread?mode=friend
async function unreadCount(req, res, next) {
  try {
    const { mode } = req.query;
    if (!mode) return res.status(400).json({ status: 'error', code: 400, message: 'mode is required' });
    const count = await messageService.getUnreadCount(req.userId, mode);
    res.json({ data: { count } });
  } catch (err) {
    next(err);
  }
}

module.exports = { openConversation, listConversations, listMessages, sendMessage, recallMessage, markRead, unreadCount };
