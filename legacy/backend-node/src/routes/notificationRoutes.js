/**
 * notificationRoutes.js — the unified notification inbox.
 *
 * Mounted twice in index.js: at /api/notifications and, as a deprecated alias
 * for the shipped iOS build, at /api/user-notifications. The two legacy
 * surfaces disagreed on HTTP verb (one used POST, the other PATCH), so every
 * mutation is registered under both.
 */

const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const ctrl = require('../controllers/notificationController');

// All notification routes require a valid JWT
router.use(authMiddleware);

// Literal paths must be declared before /:id so they aren't matched as an id
router.get('/',                ctrl.listNotifications);
router.get('/unread-count',    ctrl.getUnreadCount);
router.get('/communities',     ctrl.listCommunityNotifications); // deprecated shim

router.patch('/read-all',      ctrl.markAllAsRead);
router.post ('/read-all',      ctrl.markAllAsRead);

router.patch('/:id/read',      ctrl.markAsRead);
router.post ('/:id/read',      ctrl.markAsRead);

router.patch('/:id/unread',    ctrl.markAsUnread);
router.post ('/:id/unread',    ctrl.markAsUnread);

router.post ('/:id/resolve',   ctrl.resolveNotification);

router.delete('/:id',          ctrl.removeNotification);

module.exports = router;
