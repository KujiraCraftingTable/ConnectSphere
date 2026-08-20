/**
 * connectionRoutes.js  (toàn bộ yêu cầu JWT — danh tính lấy từ req.userId)
 *
 * GET  /api/connections/status/:targetId — trạng thái kết nối với target
 * POST /api/connections/request          — gửi kết nối  { addressee_id, mode }
 * POST /api/connections/accept           — chấp nhận    { connection_id }
 * POST /api/connections/decline          — từ chối      { connection_id }
 * POST /api/connections/cancel           — hủy request  { connection_id }
 * POST /api/connections/remove           — gỡ kết nối accepted { connection_id }
 */

const router = require('express').Router();
const { query } = require('../config/db');
const { authMiddleware } = require('./authRoutes');
const { pushUserNotification, actorPayload } = require('../services/userNotifyService');
const { personaExpr } = require('../utils/personaSql');
const logger = require('../utils/logger');

router.use(authMiddleware);

// Tìm connection giữa 2 user theo mode, bất kể chiều gửi
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

// Tạo user notification về kết nối (kèm push realtime qua socket);
// lỗi notification không được làm fail request chính
async function notifyConnection(recipientId, senderId, type, extraPayload = {}) {
  try {
    const actor = await actorPayload(senderId);
    await pushUserNotification({
      userId: recipientId,
      type,
      payload: { ...actor, ...extraPayload },
    });
  } catch (err) {
    logger.warn({ err, recipientId, type }, 'Failed to create connection notification');
  }
}

// ── GET /api/connections ──────────────────────────────────────────────────────
// Danh sách kết nối của user hiện tại kèm thông tin người kia.
// Query: ?mode=hobby|work (mặc định hobby)
//        ?status=accepted|pending_received|pending_sent (mặc định accepted)

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
// Trả về: { status: 'none' | 'pending_sent' | 'pending_received' | 'accepted'
//           | 'rejected' | 'blocked' | 'self', connection_id }
// Trạng thái tính theo mode hiện tại (?mode=hobby|work, mặc định hobby).

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
// Body: { addressee_id, mode } — requester luôn là user trong JWT

router.post('/request', async (req, res, next) => {
  try {
    const { addressee_id, mode = 'hobby' } = req.body;
    if (!addressee_id) return res.status(400).json({ error: 'addressee_id required' });
    if (!['hobby', 'work'].includes(mode)) return res.status(400).json({ error: 'Invalid mode' });
    if (req.userId === addressee_id) return res.status(400).json({ error: 'Cannot connect with yourself' });

    const { rows: [target] } = await query('SELECT id FROM users WHERE id = $1', [addressee_id]);
    if (!target) return res.status(404).json({ error: 'User not found' });

    // Không gửi được lời mời khi 2 bên có block (chiều bất kỳ)
    const { rows: blocked } = await query(
      `SELECT 1 FROM user_blocks
       WHERE (blocker_id = $1 AND blocked_id = $2)
          OR (blocker_id = $2 AND blocked_id = $1)`,
      [req.userId, addressee_id]
    );
    if (blocked.length > 0) {
      return res.status(403).json({ error: 'Cannot send request to this user' });
    }

    // Check cả 2 chiều để không tạo cặp request A→B và B→A song song
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
          // Cho phép gửi lại: reset row cũ về pending với chiều gửi mới
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
// Body: { connection_id } — chỉ addressee của request đang pending mới accept được

router.post('/accept', async (req, res, next) => {
  try {
    const { connection_id } = req.body;
    if (!connection_id) return res.status(400).json({ error: 'connection_id required' });

    // UPDATE có điều kiện status='pending' → gọi lặp không tăng count lần nữa
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

    // Kết nối là quan hệ 2 chiều: cả hai bên +1 follower và +1 following
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
// Body: { connection_id } — chỉ addressee của request đang pending mới decline được

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
// Body: { connection_id } — requester hủy request còn pending của chính mình

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
// Body: { connection_id } — gỡ một kết nối đã accepted; cả requester lẫn addressee
// đều gỡ được. Đảo ngược +1/+1 đã cộng lúc accept (không cho count xuống âm).

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
