const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const {
  listNotifications,
  markRead,
  markAllRead,
  resolveNotification,
} = require('../controllers/userNotificationController');

// All routes require auth
router.use(authMiddleware);

// read-all phải đứng trước /:id/read để không bị match nhầm thành id
router.get('/',                      listNotifications);
router.post('/read-all',             markAllRead);
router.post('/:id/read',             markRead);
router.post('/:id/resolve',          resolveNotification);

module.exports = router;
