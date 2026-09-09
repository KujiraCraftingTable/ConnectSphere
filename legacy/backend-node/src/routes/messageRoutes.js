const router = require('express').Router();
const path   = require('path');
const fs     = require('fs');
const multer = require('multer');
const { authMiddleware } = require('./authRoutes');
const ctrl = require('../controllers/messageController');

// ── Media upload (images / videos) ───────────────────────────────────────────

// Must live INSIDE backend/uploads since index.js serves static files from there
const MESSAGE_UPLOAD_DIR = path.join(__dirname, '../../uploads/messages');
fs.mkdirSync(MESSAGE_UPLOAD_DIR, { recursive: true });

// File extension is derived from the whitelisted MIME type — never trust the original filename
const EXT_BY_MIME = {
  'image/jpeg':      '.jpg',
  'image/png':       '.png',
  'image/gif':       '.gif',
  'image/webp':      '.webp',
  'video/mp4':       '.mp4',
  'video/quicktime': '.mov',
  'audio/m4a':       '.m4a',
};

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, MESSAGE_UPLOAD_DIR),
  filename:    (req, file, cb) => {
    cb(null, `${Date.now()}-${Math.random().toString(36).slice(2)}${EXT_BY_MIME[file.mimetype]}`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 50 * 1024 * 1024 }, // 50 MB
  fileFilter: (req, file, cb) => {
    cb(null, Boolean(EXT_BY_MIME[file.mimetype]));
  },
});

// POST /api/messages/upload  →  { url, message_type }
router.post('/upload', authMiddleware, upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ status: 'error', code: 400, message: 'Invalid or missing file' });
  const messageType = req.file.mimetype.startsWith('video/') ? 'video'
                     : req.file.mimetype.startsWith('audio/') ? 'voice'
                     : 'image';
  const url = `/uploads/messages/${req.file.filename}`;
  res.json({ data: { url, message_type: messageType } });
});

// ── Conversation & message routes ─────────────────────────────────────────────

router.use(authMiddleware);

router.post  ('/conversations',             ctrl.openConversation);
router.post  ('/conversations/group',       ctrl.createGroupConversation);
router.get   ('/conversations',             ctrl.listConversations);

// Conversation settings (nickname/theme shared, mute personal), media & search
router.get   ('/conversations/:id/settings', ctrl.getSettings);
router.patch ('/conversations/:id/settings', ctrl.updateSettings);
router.put   ('/conversations/:id/mute',     ctrl.setMute);
router.get   ('/conversations/:id/media',    ctrl.listMedia);
router.get   ('/conversations/:id/messages/search', ctrl.searchMessages);

// Pinned messages (any participant may pin/unpin; up to 10 per conversation)
router.get   ('/conversations/:id/pins',              ctrl.listPins);
router.post  ('/conversations/:id/pins',               ctrl.pinMessage);
router.delete('/conversations/:id/pins/:messageId',    ctrl.unpinMessage);

// Group management (owner-gated except leave) + alert-only block state
router.post  ('/conversations/:id/members',                 ctrl.addMembers);
router.delete('/conversations/:id/members/:userId',         ctrl.removeMember);
router.post  ('/conversations/:id/members/:userId/promote', ctrl.promoteOwner);
router.patch ('/conversations/:id/group',                   ctrl.updateGroup);
router.post  ('/conversations/:id/leave',                   ctrl.leaveGroup);
router.get   ('/conversations/:id/block-alert-state',       ctrl.getBlockAlertState);
router.post  ('/conversations/:id/block-alert-ack',         ctrl.acknowledgeBlockAlert);

router.get   ('/conversations/:id/messages', ctrl.listMessages);
router.post  ('/conversations/:id/messages', ctrl.sendMessage);
router.delete('/conversations/:id/messages', ctrl.clearConversation);
router.delete('/conversations/:id/messages/:messageId', ctrl.recallMessage);
router.post  ('/conversations/:id/messages/:messageId/reactions', ctrl.reactToMessage);
router.patch ('/conversations/:id/messages/:messageId/meeting-proposal',        ctrl.updateMeetingProposal);
router.post  ('/conversations/:id/messages/:messageId/meeting-proposal/cancel', ctrl.cancelMeetingProposal);
router.post  ('/conversations/:id/messages/:messageId/meeting-response',        ctrl.respondToMeeting);
router.put   ('/conversations/:id/read',     ctrl.markRead);
router.put   ('/conversations/:id/delivered', ctrl.markDelivered);
router.get   ('/unread',                     ctrl.unreadCount);

module.exports = router;
