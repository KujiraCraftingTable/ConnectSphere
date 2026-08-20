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

// GET /api/messages/conversations?mode=hobby
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
    const { content, message_type = 'text', media_url = null, reply_to_message_id = null } = req.body;
    const message = await messageService.sendMessage(
      req.params.id,
      req.userId,
      { content, messageType: message_type, mediaUrl: media_url, replyToMessageId: reply_to_message_id }
    );
    res.status(201).json({ data: message });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/messages/:messageId/reactions — body: { emoji }
async function reactToMessage(req, res, next) {
  try {
    const { emoji } = req.body;
    if (!emoji) return res.status(400).json({ status: 'error', code: 400, message: 'emoji is required' });
    const reactions = await messageService.reactToMessage(
      req.params.id, req.params.messageId, req.userId, emoji
    );
    res.json({ data: { reactions } });
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

// GET /api/messages/unread?mode=hobby
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

// GET /api/messages/conversations/:id/settings
async function getSettings(req, res, next) {
  try {
    const settings = await messageService.getSettings(req.params.id, req.userId);
    res.json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/messages/conversations/:id/settings — theme and/or nickname (shared)
async function updateSettings(req, res, next) {
  try {
    const { theme, nickname } = req.body;
    const settings = await messageService.updateSettings(req.params.id, req.userId, { theme, nickname });
    res.json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// PUT /api/messages/conversations/:id/mute — { minutes }
async function setMute(req, res, next) {
  try {
    const { minutes = null } = req.body;
    const result = await messageService.setMute(req.params.id, req.userId, minutes);
    res.json({ data: result });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/conversations/:id/media
async function listMedia(req, res, next) {
  try {
    const media = await messageService.getMedia(req.params.id, req.userId);
    res.json({ data: media });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/conversations/:id/messages/search?q=<keyword>
async function searchMessages(req, res, next) {
  try {
    const results = await messageService.searchMessages(req.params.id, req.userId, req.query.q);
    res.json({ data: results });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/messages/conversations/:id/messages — clear on my side only
async function clearConversation(req, res, next) {
  try {
    await messageService.clearConversation(req.params.id, req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  openConversation, listConversations, listMessages, sendMessage, recallMessage, markRead, unreadCount,
  getSettings, updateSettings, setMute, listMedia, searchMessages, clearConversation, reactToMessage,
};
