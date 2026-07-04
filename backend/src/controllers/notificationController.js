const notificationModel = require('../models/notificationModel');

// GET /api/notifications/communities?limit=&offset=
async function listNotifications(req, res, next) {
  try {
    const { limit = '20', offset = '0' } = req.query;
    const notifications = await notificationModel.getNotificationsForUser(req.userId, {
      limit:  parseInt(limit,  10),
      offset: parseInt(offset, 10),
    });
    res.json({ data: notifications });
  } catch (err) { next(err); }
}

// PATCH /api/notifications/:id/read
async function markAsRead(req, res, next) {
  try {
    const updated = await notificationModel.markAsRead(req.params.id, req.userId);
    if (!updated) {
      const err = new Error('Notification not found');
      err.status = 404;
      return next(err);
    }
    res.json({ status: 'ok' });
  } catch (err) { next(err); }
}

// PATCH /api/notifications/read-all
async function markAllAsRead(req, res, next) {
  try {
    await notificationModel.markAllAsRead(req.userId);
    res.json({ status: 'ok' });
  } catch (err) { next(err); }
}

// GET /api/notifications/unread-count
async function getUnreadCount(req, res, next) {
  try {
    const count = await notificationModel.getUnreadCount(req.userId);
    res.json({ data: { count } });
  } catch (err) { next(err); }
}

module.exports = { listNotifications, markAsRead, markAllAsRead, getUnreadCount };
