/**
 * storyRoutes.js — Stories 24h
 * POST   /api/stories           — đăng story  { image_url }
 * GET    /api/stories           — story của mình + của connections (chưa hết hạn)
 * POST   /api/stories/:id/view  — đánh dấu đã xem
 * DELETE /api/stories/:id       — xóa story của mình
 */

const router = require('express').Router();
const { query } = require('../config/db');
const { authMiddleware } = require('./authRoutes');

router.use(authMiddleware);

// ── POST /api/stories ─────────────────────────────────────────────────────────

router.post('/', async (req, res, next) => {
  try {
    const { image_url } = req.body;
    if (!image_url || typeof image_url !== 'string') {
      return res.status(400).json({ error: 'image_url is required' });
    }

    const { rows: [story] } = await query(
      `INSERT INTO stories (author_id, image_url)
       VALUES ($1, $2)
       RETURNING id, author_id, image_url, created_at, expires_at`,
      [req.userId, image_url]
    );
    res.status(201).json({ data: story });
  } catch (err) { next(err); }
});

// ── GET /api/stories ──────────────────────────────────────────────────────────
// Trả về flat list (client tự group theo author): story của mình đứng đầu,
// chỉ lấy từ connections đã accepted, loại user block 2 chiều.

router.get('/', async (req, res, next) => {
  try {
    const { rows } = await query(
      `SELECT s.id, s.author_id, s.image_url, s.created_at, s.expires_at,
              json_build_object(
                'id',           u.id,
                'username',     u.username,
                'display_name', u.display_name,
                'avatar_color', u.avatar_color,
                'avatar_url',   u.avatar_url
              ) AS author,
              EXISTS(
                SELECT 1 FROM story_views sv
                WHERE sv.story_id = s.id AND sv.viewer_id = $1
              ) AS viewed
       FROM stories s
       JOIN users u ON u.id = s.author_id
       WHERE s.expires_at > NOW()
         AND (
           s.author_id = $1
           OR EXISTS (
             SELECT 1 FROM connections c
             WHERE c.status = 'accepted'
               AND ((c.requester_id = s.author_id AND c.addressee_id = $1)
                 OR (c.addressee_id = s.author_id AND c.requester_id = $1))
           )
         )
         AND NOT EXISTS (
           SELECT 1 FROM user_blocks ub
           WHERE (ub.blocker_id = $1 AND ub.blocked_id = s.author_id)
              OR (ub.blocker_id = s.author_id AND ub.blocked_id = $1)
         )
       ORDER BY (s.author_id = $1) DESC, s.author_id, s.created_at ASC`,
      [req.userId]
    );
    res.json({ data: rows });
  } catch (err) { next(err); }
});

// ── POST /api/stories/:id/view ────────────────────────────────────────────────

router.post('/:id/view', async (req, res, next) => {
  try {
    const { rows: [story] } = await query(
      `SELECT id FROM stories WHERE id = $1 AND expires_at > NOW()`,
      [req.params.id]
    );
    if (!story) return res.status(404).json({ error: 'Story not found' });

    await query(
      `INSERT INTO story_views (story_id, viewer_id)
       VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [req.params.id, req.userId]
    );
    res.json({ status: 'ok' });
  } catch (err) { next(err); }
});

// ── DELETE /api/stories/:id ───────────────────────────────────────────────────

router.delete('/:id', async (req, res, next) => {
  try {
    const { rowCount } = await query(
      `DELETE FROM stories WHERE id = $1 AND author_id = $2`,
      [req.params.id, req.userId]
    );
    if (rowCount === 0) return res.status(404).json({ error: 'Story not found' });
    res.json({ status: 'ok' });
  } catch (err) { next(err); }
});

module.exports = router;
