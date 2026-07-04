const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const ctrl = require('../controllers/notificationController');

// All notification routes require a valid JWT
router.use(authMiddleware);

// read-all must be declared before /:id to avoid treating "read-all" as an ID param
router.patch('/read-all',     ctrl.markAllAsRead);
router.get('/unread-count',   ctrl.getUnreadCount);
router.get('/communities',    ctrl.listNotifications);
router.patch('/:id/read',     ctrl.markAsRead);

module.exports = router;
