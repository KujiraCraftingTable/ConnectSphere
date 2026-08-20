const router = require('express').Router();
const path   = require('path');
const fs     = require('fs');
const multer = require('multer');
const { authMiddleware } = require('./authRoutes');
const ctrl = require('../controllers/messageController');

// ── Media upload (images / videos) ───────────────────────────────────────────

// Phải nằm TRONG backend/uploads vì index.js serve static từ đó
const MESSAGE_UPLOAD_DIR = path.join(__dirname, '../../uploads/messages');
fs.mkdirSync(MESSAGE_UPLOAD_DIR, { recursive: true });

// Đuôi file suy ra từ MIME type đã whitelist — không tin tên file gốc
const EXT_BY_MIME = {
  'image/jpeg':      '.jpg',
  'image/png':       '.png',
  'image/gif':       '.gif',
  'image/webp':      '.webp',
  'video/mp4':       '.mp4',
  'video/quicktime': '.mov',
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
  const messageType = req.file.mimetype.startsWith('video/') ? 'video' : 'image';
  const url = `/uploads/messages/${req.file.filename}`;
  res.json({ data: { url, message_type: messageType } });
});

// ── Conversation & message routes ─────────────────────────────────────────────

router.use(authMiddleware);

router.post  ('/conversations',             ctrl.openConversation);
router.get   ('/conversations',             ctrl.listConversations);

// Conversation settings (nickname/theme shared, mute personal), media & search
router.get   ('/conversations/:id/settings', ctrl.getSettings);
router.patch ('/conversations/:id/settings', ctrl.updateSettings);
router.put   ('/conversations/:id/mute',     ctrl.setMute);
router.get   ('/conversations/:id/media',    ctrl.listMedia);
router.get   ('/conversations/:id/messages/search', ctrl.searchMessages);

router.get   ('/conversations/:id/messages', ctrl.listMessages);
router.post  ('/conversations/:id/messages', ctrl.sendMessage);
router.delete('/conversations/:id/messages', ctrl.clearConversation);
router.delete('/conversations/:id/messages/:messageId', ctrl.recallMessage);
router.post  ('/conversations/:id/messages/:messageId/reactions', ctrl.reactToMessage);
router.put   ('/conversations/:id/read',     ctrl.markRead);
router.get   ('/unread',                     ctrl.unreadCount);

module.exports = router;
