const analyticsService = require('../services/analyticsService');

// GET /api/communities/:id/analytics?days=30
async function getAnalytics(req, res, next) {
  try {
    const { days = '30' } = req.query;
    const summary = await analyticsService.getAnalyticsSummary(
      req.params.id,
      req.userId,
      parseInt(days, 10)
    );
    res.json({ data: summary });
  } catch (err) { next(err); }
}

module.exports = { getAnalytics };
