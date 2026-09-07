/**
 * connectionRoutes.js  (all routes require JWT — identity comes from req.userId)
 *
 * GET  /api/connections/status/:targetId — connection status with a target user
 * POST /api/connections/request          — send a connection request { addressee_id, mode }
 * POST /api/connections/accept           — accept   { connection_id }
 * POST /api/connections/decline          — decline  { connection_id }
 * POST /api/connections/cancel           — cancel a pending request { connection_id }
 * POST /api/connections/remove           — remove an accepted connection { connection_id }
 */

const router = require('express').Router();
const { query } = require('../config/db');
const { authMiddleware } = require('./authRoutes');
const { pushUserNotification, actorPayload } = require('../services/userNotifyService');
const { personaExpr } = require('../utils/personaSql');
const logger = require('../utils/logger');

router.use(authMiddleware);

// Find the connection between 2 users for a given mode, regardless of who sent it
async function findConnection(userA, userB, mode) {
  const { rows } = await query(
    `SELECT id, requester_id, addressee_id, status
     FROM connections
     WHERE mode = $3
       AND ((requester_id = $1 AND addressee_id = $2)
         OR (requester_id = $2 AND addressee_id = $1))
     ORDER BY updated_at DESC
     LIMIT 1`,
    [userA, userB, mode]
  );
  return rows[0] || null;
}

// Create a user notification about the connection (with a realtime push via socket);
// a notification failure must not fail the main request
async function notifyConnection(recipientId, senderId, type, extraPayload = {}) {
  try {
    const actor = await actorPayload(senderId);
    await pushUserNotification({
      userId:  recipientId,
      type,
      actorId: senderId,
      payload: { ...actor, ...extraPayload },
    });
  } catch (err) {
    logger.warn({ err, recipientId, type }, 'Failed to create connection notification');
  }
}

// ── GET /api/connections ──────────────────────────────────────────────────────
// List of the current user's connections with info about the other person.
// Query: ?mode=hobby|work (default hobby)
//        ?status=accepted|pending_received|pending_sent (default accepted)

router.get('/', async (req, res, next) => {
  try {
    const mode = ['hobby', 'work'].includes(req.query.mode) ? req.query.mode : 'hobby';
    const status = ['accepted', 'pending_received', 'pending_sent'].includes(req.query.status)
      ? req.query.status : 'accepted';

    let statusClause;
    if (status === 'accepted') {
      statusClause = `c.status = 'accepted' AND (c.requester_id = $1 OR c.addressee_id = $1)`;
    } else if (status === 'pending_received') {
      statusClause = `c.status = 'pending' AND c.addressee_id = $1`;
    } else {
      statusClause = `c.status = 'pending' AND c.requester_id = $1`;
    }

    const { rows } = await query(
      `SELECT c.id AS connection_id, c.status, c.mode, c.updated_at,
              json_build_object(
                'id',           u.id,
                'username',     u.username,
                'display_name', ${personaExpr('display_name', 'c.mode')},
                'avatar_color', u.avatar_color,
                'avatar_url',   ${personaExpr('avatar_url', 'c.mode')},
                'job_title',    u.job_title,
                'company',      u.company,
                'location',     u.location
              ) AS user
       FROM connections c
       JOIN users u ON u.id = CASE
         WHEN c.requester_id = $1 THEN c.addressee_id
         ELSE c.requester_id
       END
       WHERE c.mode = $2 AND ${statusClause}
       ORDER BY c.updated_at DESC`,
      [req.userId, mode]
    );

    res.json({ data: rows });
  } catch (err) { next(err); }
});

// ── GET /api/connections/status/:targetId ─────────────────────────────────────
// Returns: { status: 'none' | 'pending_sent' | 'pending_received' | 'accepted'
//           | 'rejected' | 'blocked' | 'self', connection_id }
// Status is computed for the given mode (?mode=hobby|work, default hobby).

router.get('/status/:targetId', async (req, res, next) => {
  try {
    const { targetId } = req.params;
    const mode = ['hobby', 'work'].includes(req.query.mode) ? req.query.mode : 'hobby';

    if (req.userId === targetId) return res.json({ status: 'self', connection_id: null });

    const conn = await findConnection(req.userId, targetId, mode);
    if (!conn) return res.json({ status: 'none', connection_id: null });

    let status;
    if (conn.status === 'accepted') {
      status = 'accepted';
    } else if (conn.status === 'pending') {
      status = conn.requester_id === req.userId ? 'pending_sent' : 'pending_received';
    } else {
      status = conn.status; // rejected, blocked
    }

    res.json({ status, connection_id: conn.id });
  } catch (err) { next(err); }
});

// ── POST /api/connections/request ─────────────────────────────────────────────
// Body: { addressee_id, mode } — requester is always the user from the JWT

router.post('/request', async (req, res, next) => {
  try {
    const { addressee_id, mode = 'hobby' } = req.body;
    if (!addressee_id) return res.status(400).json({ error: 'addressee_id required' });
    if (!['hobby', 'work'].includes(mode)) return res.status(400).json({ error: 'Invalid mode' });
    if (req.userId === addressee_id) return res.status(400).json({ error: 'Cannot connect with yourself' });

    const { rows: [target] } = await query('SELECT id FROM users WHERE id = $1', [addressee_id]);
    if (!target) return res.status(404).json({ error: 'User not found' });

    // Can't send a request when the two sides have a block between them (either direction)
    const { rows: blocked } = await query(
      `SELECT 1 FROM user_blocks
       WHERE (blocker_id = $1 AND blocked_id = $2)
          OR (blocker_id = $2 AND blocked_id = $1)`,
      [req.userId, addressee_id]
    );
    if (blocked.length > 0) {
      return res.status(403).json({ error: 'Cannot send request to this user' });
    }

    // Check both directions so we don't create a parallel A→B and B→A request pair
    const existing = await findConnection(req.userId, addressee_id, mode);

    if (existing) {
      switch (existing.status) {
        case 'accepted':
          return res.json({ connection_id: existing.id, status: 'accepted' });
        case 'pending':
          return res.json({
            connection_id: existing.id,
            status: existing.requester_id === req.userId ? 'pending_sent' : 'pending_received',
          });
        case 'blocked':
          return res.status(403).json({ error: 'Cannot send request to this user' });
        case 'rejected': {
          // Allow re-sending: reset the old row to pending with the new sender direction
          const { rows: [updated] } = await query(
            `UPDATE connections
             SET requester_id = $1, addressee_id = $2, status = 'pending', updated_at = NOW()
             WHERE id = $3
             RETURNING id`,
            [req.userId, addressee_id, existing.id]
          );
          await notifyConnection(addressee_id, req.userId, 'connection_request',
            { mode, connectionId: updated.id });
          return res.status(201).json({ connection_id: updated.id, status: 'pending_sent' });
        }
      }
    }

    const { rows: [created] } = await query(
      `INSERT INTO connections (requester_id, addressee_id, mode)
       VALUES ($1, $2, $3)
       RETURNING id`,
      [req.userId, addressee_id, mode]
    );

    await notifyConnection(addressee_id, req.userId, 'connection_request',
      { mode, connectionId: created.id });

    res.status(201).json({ connection_id: created.id, status: 'pending_sent' });
  } catch (err) { next(err); }
});

// ── POST /api/connections/accept ──────────────────────────────────────────────
// Body: { connection_id } — only the addressee of a pending request can accept it

router.post('/accept', async (req, res, next) => {
  try {
    const { connection_id } = req.body;
    if (!connection_id) return res.status(400).json({ error: 'connection_id required' });

    // Conditional UPDATE on status='pending' → a repeated call won't bump the count again
    const { rows: [conn] } = await query(
      `UPDATE connections
       SET status = 'accepted', updated_at = NOW()
       WHERE id = $1 AND addressee_id = $2 AND status = 'pending'
       RETURNING id, requester_id, addressee_id, mode`,
      [connection_id, req.userId]
    );
    if (!conn) {
      return res.status(409).json({ error: 'Request not found, not yours, or already handled' });
    }

    // A connection is a mutual relationship: both sides get +1 follower and +1 following
    await query(
      `UPDATE users
       SET follower_count = follower_count + 1, following_count = following_count + 1
       WHERE id IN ($1, $2)`,
      [conn.requester_id, conn.addressee_id]
    );

    await notifyConnection(conn.requester_id, req.userId, 'connection_accepted', { mode: conn.mode });

    res.json({ status: 'accepted', connection_id: conn.id });
  } catch (err) { next(err); }
});

// ── POST /api/connections/decline ─────────────────────────────────────────────
// Body: { connection_id } — only the addressee of a pending request can decline it

router.post('/decline', async (req, res, next) => {
  try {
    const { connection_id } = req.body;
    if (!connection_id) return res.status(400).json({ error: 'connection_id required' });

    const { rowCount } = await query(
      `UPDATE connections SET status = 'rejected', updated_at = NOW()
       WHERE id = $1 AND addressee_id = $2 AND status = 'pending'`,
      [connection_id, req.userId]
    );
    if (rowCount === 0) {
      return res.status(409).json({ error: 'Request not found, not yours, or already handled' });
    }
    res.json({ status: 'rejected' });
  } catch (err) { next(err); }
});

// ── POST /api/connections/cancel ──────────────────────────────────────────────
// Body: { connection_id } — requester cancels their own still-pending request

router.post('/cancel', async (req, res, next) => {
  try {
    const { connection_id } = req.body;
    if (!connection_id) return res.status(400).json({ error: 'connection_id required' });

    await query(
      `DELETE FROM connections
       WHERE id = $1 AND requester_id = $2 AND status = 'pending'`,
      [connection_id, req.userId]
    );
    res.json({ status: 'none' });
  } catch (err) { next(err); }
});

// ── POST /api/connections/remove ──────────────────────────────────────────────
// Body: { connection_id } — removes an accepted connection; either the requester
// or the addressee can remove it. Reverses the +1/+1 applied on accept (never lets the count go negative).

router.post('/remove', async (req, res, next) => {
  try {
    const { connection_id } = req.body;
    if (!connection_id) return res.status(400).json({ error: 'connection_id required' });

    const { rows: [removed] } = await query(
      `DELETE FROM connections
       WHERE id = $1 AND status = 'accepted'
         AND (requester_id = $2 OR addressee_id = $2)
       RETURNING requester_id, addressee_id`,
      [connection_id, req.userId]
    );
    if (!removed) {
      return res.status(409).json({ error: 'Connection not found or not yours' });
    }

    await query(
      `UPDATE users
       SET follower_count  = GREATEST(follower_count  - 1, 0),
           following_count = GREATEST(following_count - 1, 0)
       WHERE id IN ($1, $2)`,
      [removed.requester_id, removed.addressee_id]
    );

    res.json({ status: 'none' });
  } catch (err) { next(err); }
});

module.exports = router;
