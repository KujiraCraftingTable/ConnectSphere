const userNotifModel = require('../models/userNotificationModel');
const { query }      = require('../config/db');
const logger         = require('../utils/logger');

/** GET /api/user-notifications — list all notifications for the current user. */
async function listNotifications(req, res, next) {
  try {
    const limit  = parseInt(req.query.limit  ?? '30', 10);
    const offset = parseInt(req.query.offset ?? '0',  10);

    const notifications = await userNotifModel.listForUser(req.userId, { limit, offset });
    const unread        = await userNotifModel.getUnreadCount(req.userId);

    res.json({ data: notifications, unread });
  } catch (err) {
    next(err);
  }
}

/** POST /api/user-notifications/read-all — mark all notifications as read. */
async function markAllRead(req, res, next) {
  try {
    await userNotifModel.markAllRead(req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

/** POST /api/user-notifications/:id/read — mark a notification as read. */
async function markRead(req, res, next) {
  try {
    const updated = await userNotifModel.markRead(req.params.id, req.userId);
    if (!updated) {
      const err = new Error('Notification not found');
      err.status = 404;
      return next(err);
    }
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

/**
 * POST /api/user-notifications/:id/resolve
 * Body: { action: 'keep' | 'switch' }
 *
 * 'keep'   — mark resolved, leave post mode unchanged
 * 'switch' — update post mode to suggestedMode, then mark resolved
 */
async function resolveNotification(req, res, next) {
  try {
    const { action } = req.body;
    if (!['keep', 'switch'].includes(action)) {
      const err = new Error('action must be keep or switch');
      err.status = 400;
      return next(err);
    }

    const notif = await userNotifModel.findById(req.params.id);
    if (!notif || notif.user_id !== req.userId) {
      const err = new Error('Notification not found');
      err.status = 404;
      return next(err);
    }
    if (notif.resolved_at) {
      return res.json({ status: 'ok', message: 'Already resolved' });
    }

    if (action === 'switch' && notif.post_id && notif.payload?.suggestedMode) {
      await query(
        `UPDATE posts SET mode = $1 WHERE id = $2`,
        [notif.payload.suggestedMode, notif.post_id]
      );
      logger.info(
        { postId: notif.post_id, newMode: notif.payload.suggestedMode },
        'Post mode switched via notification resolve'
      );
    }

    await userNotifModel.resolve(req.params.id, req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

module.exports = { listNotifications, markRead, markAllRead, resolveNotification };
