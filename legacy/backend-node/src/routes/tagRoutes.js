/**
 * tagRoutes.js
 * GET /api/tags/trending?limit=10 — most popular tags in the last 7 days
 * GET /api/tags/suggest?prefix=<text>&limit=10 — prefix-match suggestions
 *   for the hashtag composer's autocomplete (typing "cof" surfaces "coffee")
 * (browsing posts by tag uses GET /api/posts?tag=<tag>)
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

router.get('/suggest', async (req, res, next) => {
  try {
    const prefix = (req.query.prefix || '').trim();
    if (!prefix) {
      return res.status(400).json({ error: 'prefix is required' });
    }
    const limit = Math.min(parseInt(req.query.limit || '10', 10) || 10, 20);

    // Deliberately does NOT filter by source/visibility — a hidden AI tag's
    // text having been used before is still a useful suggestion for a user
    // who wants to deliberately type (and thus show) that same hashtag.
    const { rows } = await query(
      `SELECT tag, COUNT(*)::INT AS usage_count
       FROM post_tags
       WHERE tag ILIKE $1 || '%'
       GROUP BY tag
       ORDER BY usage_count DESC
       LIMIT $2`,
      [prefix, limit]
    );

    res.json({ data: rows });
  } catch (err) { next(err); }
});

module.exports = router;
