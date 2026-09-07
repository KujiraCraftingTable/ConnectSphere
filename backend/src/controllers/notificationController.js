/**
 * notificationController.js — the unified notification inbox.
 *
 * Since migration 026 there is one table behind every notification, so this
 * controller serves both the /api/notifications and /api/user-notifications
 * mounts (the latter kept as a deprecated alias for the shipped iOS build).
 */

const userNotifModel = require('../models/userNotificationModel');
const notifyService  = require('../services/userNotifyService');
const { query }      = require('../config/db');
const { emitToUser } = require('../utils/realtime');
const logger         = require('../utils/logger');
const { typesForCategory, CATEGORIES } = require('../utils/notificationTypes');

const DEFAULT_LIMIT = 30;
const MAX_LIMIT     = 100;

/** Opaque cursor so clients can't hand-craft one: base64 of "<updated_at>|<id>". */
function encodeCursor(row) {
  const updatedAt = row.updated_at instanceof Date
    ? row.updated_at.toISOString()
    : row.updated_at;
  return Buffer.from(`${updatedAt}|${row.id}`).toString('base64');
}

function decodeCursor(cursor) {
  if (!cursor) return { cursorUpdatedAt: null, cursorId: null };
  try {
    const [updatedAt, id] = Buffer.from(cursor, 'base64').toString('utf8').split('|');
    if (!updatedAt || !id) return { cursorUpdatedAt: null, cursorId: null };
    return { cursorUpdatedAt: updatedAt, cursorId: id };
  } catch {
    return { cursorUpdatedAt: null, cursorId: null };
  }
}

/** Category query param → the list of types it covers (null = every type). */
function typesFromQuery(req) {
  const category = req.query.category;
  if (!category || category === 'all') return null;
  if (!CATEGORIES.includes(category)) return null;
  return typesForCategory(category);
}

/**
 * GET / — one page of notifications, newest first.
 * Query: limit, cursor, offset (legacy), filter=all|unread, category
 */
async function listNotifications(req, res, next) {
  try {
    const limit = Math.min(
      parseInt(req.query.limit ?? String(DEFAULT_LIMIT), 10) || DEFAULT_LIMIT,
      MAX_LIMIT
    );
    const offset = parseInt(req.query.offset ?? '0', 10) || 0;
    const { cursorUpdatedAt, cursorId } = decodeCursor(req.query.cursor);

    const { rows, hasMore } = await userNotifModel.listForUser(req.userId, {
      limit,
      offset,
      unreadOnly: req.query.filter === 'unread',
      types: typesFromQuery(req),
      cursorUpdatedAt,
      cursorId,
    });

    const { unread, byCategory } = await notifyService.unreadSummary(req.userId);

    res.json({
      data:       rows.map(notifyService.toNotificationDTO),
      unread,
      counts:     { total: unread, ...byCategory },
      hasMore,
      nextCursor: hasMore && rows.length ? encodeCursor(rows[rows.length - 1]) : null,
    });
  } catch (err) {
    next(err);
  }
}

/** GET /unread-count — badge counts. Query: scope=all|social|community|chat */
async function getUnreadCount(req, res, next) {
  try {
    const { unread, byCategory } = await notifyService.unreadSummary(req.userId);
    const scope = req.query.scope;
    const count = scope && CATEGORIES.includes(scope) ? byCategory[scope] : unread;

    res.json({ data: { count, byCategory } });
  } catch (err) {
    next(err);
  }
}

/** Shared handler for marking one notification read or unread. */
function setReadHandler(isRead) {
  return async function handler(req, res, next) {
    try {
      const updated = await userNotifModel.setRead(req.params.id, req.userId, isRead);
      if (!updated) {
        const err = new Error('Notification not found');
        err.status = 404;
        return next(err);
      }

      emitToUser(req.userId, 'notification_read', { ids: [req.params.id], isRead });
      const { unread } = await notifyService.unreadSummary(req.userId);
      await notifyService.emitCounts(req.userId);

      res.json({ status: 'ok', data: { unread } });
    } catch (err) {
      next(err);
    }
  };
}

const markAsRead   = setReadHandler(true);
const markAsUnread = setReadHandler(false);

/** PATCH|POST /read-all — mark everything read, optionally within one category. */
async function markAllAsRead(req, res, next) {
  try {
    const types = typesFromQuery(req);
    const ids   = await userNotifModel.markAllRead(req.userId, { types });

    emitToUser(req.userId, 'notification_read', {
      readAll: true,
      category: req.query.category ?? 'all',
      ids,
    });
    const { unread } = await notifyService.unreadSummary(req.userId);
    await notifyService.emitCounts(req.userId);

    res.json({ status: 'ok', data: { unread } });
  } catch (err) {
    next(err);
  }
}

/** DELETE /:id — permanently remove one notification. */
async function removeNotification(req, res, next) {
  try {
    const deleted = await userNotifModel.deleteForUser(req.params.id, req.userId);
    if (!deleted) {
      const err = new Error('Notification not found');
      err.status = 404;
      return next(err);
    }

    emitToUser(req.userId, 'notification_deleted', { id: req.params.id });
    const { unread } = await notifyService.unreadSummary(req.userId);
    await notifyService.emitCounts(req.userId);

    res.json({ status: 'ok', data: { unread } });
  } catch (err) {
    next(err);
  }
}

/**
 * POST /:id/resolve — Body: { action: 'keep' | 'switch' }
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
    await notifyService.emitCounts(req.userId);
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

/**
 * GET /communities — compatibility shim for the pre-026 community inbox.
 * Serves the old row shape out of the unified table so an older client build
 * keeps working. Remove once no shipped client calls it.
 */
async function listCommunityNotifications(req, res, next) {
  try {
    const limit  = Math.min(parseInt(req.query.limit ?? '20', 10) || 20, MAX_LIMIT);
    const offset = parseInt(req.query.offset ?? '0', 10) || 0;

    const { rows } = await userNotifModel.listForUser(req.userId, {
      limit,
      offset,
      types: typesForCategory('community'),
    });

    res.json({
      data: rows.map((row) => ({
        id:             row.id,
        community_id:   row.community_id,
        type:           row.type,
        ref_id:         row.entity_id ?? row.post_id ?? null,
        is_read:        row.is_read,
        created_at:     row.created_at,
        community_name: row.community_name,
      })),
    });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listNotifications,
  getUnreadCount,
  markAsRead,
  markAsUnread,
  markAllAsRead,
  removeNotification,
  resolveNotification,
  listCommunityNotifications,
};
