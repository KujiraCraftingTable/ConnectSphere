const { getRecommendedFeed } = require('../models/feedModel');

// GET /api/feed/recommendations?mode=hobby|work&cursor=<token>&limit=20
async function getRecommendations(req, res, next) {
  try {
    const { mode, cursor, limit = '20' } = req.query;

    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ status: 'error', message: 'mode must be hobby or work' });
    }

    const parsedLimit = Math.min(parseInt(limit, 10) || 20, 50);

    const { posts, nextCursor } = await getRecommendedFeed(req.userId, {
      mode,
      cursor: cursor ?? null,
      limit:  parsedLimit,
    });

    res.json({ data: posts, nextCursor });
  } catch (err) {
    next(err);
  }
}

module.exports = { getRecommendations };
