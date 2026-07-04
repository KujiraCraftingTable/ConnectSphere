/**
 * tagRoutes.js
 * GET /api/tags/trending?limit=10 — tag phổ biến nhất 7 ngày gần đây
 * (duyệt bài theo tag dùng GET /api/posts?tag=<tag>)
 */

const router = require('express').Router();
const { query } = require('../config/db');
const { authMiddleware } = require('./authRoutes');

router.use(authMiddleware);

router.get('/trending', async (req, res, next) => {
  try {
    const limit = Math.min(parseInt(req.query.limit || '10', 10) || 10, 30);

    const { rows } = await query(
      `SELECT pt.tag, COUNT(*)::INT AS post_count
       FROM post_tags pt
       JOIN posts p ON p.id = pt.post_id
       WHERE p.status = 'posted'
         AND p.created_at >= NOW() - INTERVAL '7 days'
       GROUP BY pt.tag
       ORDER BY post_count DESC, pt.tag
       LIMIT $1`,
      [limit]
    );

    res.json({ data: rows });
  } catch (err) { next(err); }
});

module.exports = router;
