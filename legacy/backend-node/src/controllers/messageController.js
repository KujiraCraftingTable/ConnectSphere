const messageService = require('../services/messageService');
const { emitToUser } = require('../utils/realtime');

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

// POST /api/messages/conversations/group — body: { member_ids: [...], mode, name? }
async function createGroupConversation(req, res, next) {
  try {
    const { member_ids, mode, name } = req.body;
    if (!Array.isArray(member_ids) || member_ids.length === 0) {
      return res.status(400).json({ status: 'error', code: 400, message: 'member_ids is required' });
    }
    if (!mode) return res.status(400).json({ status: 'error', code: 400, message: 'mode is required' });
    const conversation = await messageService.createGroupConversation(req.userId, member_ids, mode, name);
    res.status(201).json({ data: conversation });
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
// For message_type: "meeting", body also carries meeting_proposal:
//   { title, location, starts_at, ends_at, reminder_offset, reminder_at }
// reminder_offset/reminder_at are optional — messageService.validateMeetingProposal
// fills in a default when omitted (e.g. a caller that predates this feature).
// For message_type: "voice", body also carries voice_duration_seconds (int)
// and voice_waveform (~40 normalized 0.0-1.0 floats), alongside media_url.
async function sendMessage(req, res, next) {
  try {
    const {
      content, message_type = 'text', media_url = null, reply_to_message_id = null, meeting_proposal = null,
      voice_duration_seconds = null, voice_waveform = null,
    } = req.body;
    const meetingProposal = meeting_proposal ? {
      title:          meeting_proposal.title,
      location:       meeting_proposal.location,
      startsAt:       meeting_proposal.starts_at,
      endsAt:         meeting_proposal.ends_at,
      reminderOffset: meeting_proposal.reminder_offset,
      reminderAt:     meeting_proposal.reminder_at,
    } : null;
    const message = await messageService.sendMessage(
      req.params.id,
      req.userId,
      {
        content, messageType: message_type, mediaUrl: media_url, replyToMessageId: reply_to_message_id, meetingProposal,
        voiceDurationSeconds: voice_duration_seconds, voiceWaveform: voice_waveform,
      }
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

// PATCH /api/messages/conversations/:id/messages/:messageId/meeting-proposal — reschedule
async function updateMeetingProposal(req, res, next) {
  try {
    const { title, location, starts_at, ends_at, reminder_offset, reminder_at } = req.body;
    const proposal = await messageService.updateMeetingProposal(
      req.params.id, req.params.messageId, req.userId,
      { title, location, startsAt: starts_at, endsAt: ends_at, reminderOffset: reminder_offset, reminderAt: reminder_at }
    );
    res.json({ data: proposal });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/messages/:messageId/meeting-proposal/cancel
async function cancelMeetingProposal(req, res, next) {
  try {
    const proposal = await messageService.cancelMeetingProposal(req.params.id, req.params.messageId, req.userId);
    res.json({ data: proposal });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/messages/:messageId/meeting-response — body: { status }
async function respondToMeeting(req, res, next) {
  try {
    const { status } = req.body;
    if (!status) return res.status(400).json({ status: 'error', code: 400, message: 'status is required' });
    const proposal = await messageService.respondToMeeting(req.params.id, req.params.messageId, req.userId, status);
    res.json({ data: proposal });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/messages/conversations/:id/messages/:messageId — recall your own message
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

// PUT /api/messages/conversations/:id/delivered — REST catch-up: mark all of
// the caller's outstanding 'sent' messages in this conversation as delivered
// (used when the recipient reconnects/opens the chat after being offline).
// Notifies each affected sender individually via their personal socket room.
async function markDelivered(req, res, next) {
  try {
    const updated = await messageService.deliverConversation(req.params.id, req.userId);
    updated.forEach((row) => {
      emitToUser(row.sender_id, 'message_delivered', { conversationId: req.params.id, messageId: row.id });
    });
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

// PATCH /api/messages/conversations/:id/settings — theme and/or nickname (shared).
// target_user_id is required to set a nickname in a group (ignored for 1:1,
// which always targets "the other person" as before).
async function updateSettings(req, res, next) {
  try {
    const { theme, nickname, target_user_id } = req.body;
    const settings = await messageService.updateSettings(
      req.params.id, req.userId, { theme, nickname, targetUserId: target_user_id }
    );
    res.json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/members — body: { member_ids: [...] } — owner-only
async function addMembers(req, res, next) {
  try {
    const { member_ids } = req.body;
    if (!Array.isArray(member_ids) || member_ids.length === 0) {
      return res.status(400).json({ status: 'error', code: 400, message: 'member_ids is required' });
    }
    const settings = await messageService.addMembers(req.params.id, req.userId, member_ids);
    res.status(200).json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/messages/conversations/:id/members/:userId — owner-only (kick)
async function removeMember(req, res, next) {
  try {
    const result = await messageService.removeMember(req.params.id, req.userId, req.params.userId);
    res.json({ data: result });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/members/:userId/promote — owner-only
async function promoteOwner(req, res, next) {
  try {
    const settings = await messageService.promoteOwner(req.params.id, req.userId, req.params.userId);
    res.json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/messages/conversations/:id/group — body: { name?, avatar_url?, avatar_color? } — owner-only
async function updateGroup(req, res, next) {
  try {
    const { name, avatar_url, avatar_color } = req.body;
    let settings;
    if (name !== undefined) {
      settings = await messageService.renameGroup(req.params.id, req.userId, name);
    }
    if (avatar_url !== undefined || avatar_color !== undefined) {
      settings = await messageService.updateGroupAvatar(
        req.params.id, req.userId, { avatarUrl: avatar_url, avatarColor: avatar_color }
      );
    }
    if (!settings) {
      return res.status(400).json({ status: 'error', code: 400, message: 'name, avatar_url or avatar_color is required' });
    }
    res.json({ data: settings });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/leave — any member; auto-promotes the
// earliest-joined remaining member if the leaver is the sole owner.
async function leaveGroup(req, res, next) {
  try {
    await messageService.leaveGroup(req.params.id, req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

// GET /api/messages/conversations/:id/block-alert-state — group-only; always
// { shouldAlert: false } for 1:1 (which uses the existing hard block instead)
async function getBlockAlertState(req, res, next) {
  try {
    const state = await messageService.getBlockAlertState(req.params.id, req.userId);
    res.json({ data: state });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/block-alert-ack — acknowledge the
// current blocked-set so the alert doesn't re-fire until it changes
async function acknowledgeBlockAlert(req, res, next) {
  try {
    const result = await messageService.acknowledgeBlockAlert(req.params.id, req.userId);
    res.json({ data: result });
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

// GET /api/messages/conversations/:id/pins
async function listPins(req, res, next) {
  try {
    const pins = await messageService.listPins(req.params.id, req.userId);
    res.json({ data: pins });
  } catch (err) {
    next(err);
  }
}

// POST /api/messages/conversations/:id/pins — body: { message_id, expires_at? }
async function pinMessage(req, res, next) {
  try {
    const { message_id, expires_at } = req.body;
    if (!message_id) return res.status(400).json({ status: 'error', code: 400, message: 'message_id is required' });
    const pin = await messageService.pinMessage(req.params.id, message_id, req.userId, expires_at);
    res.status(201).json({ data: pin });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/messages/conversations/:id/pins/:messageId — any participant may unpin
async function unpinMessage(req, res, next) {
  try {
    const result = await messageService.unpinMessage(req.params.id, req.params.messageId, req.userId);
    res.json({ data: result });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  openConversation, createGroupConversation, listConversations, listMessages, sendMessage, recallMessage, markRead, markDelivered, unreadCount,
  getSettings, updateSettings, setMute, listMedia, searchMessages, clearConversation, reactToMessage,
  updateMeetingProposal, cancelMeetingProposal, respondToMeeting,
  addMembers, removeMember, promoteOwner, updateGroup, leaveGroup, getBlockAlertState, acknowledgeBlockAlert,
  listPins, pinMessage, unpinMessage,
};
