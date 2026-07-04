const recommendationService = require('../services/recommendationService');
const communityService      = require('../services/communityService');

// GET /api/communities/recommendations?limit=10
async function getRecommendations(req, res, next) {
  try {
    const { limit = '10' } = req.query;
    const communities = await recommendationService.getRecommendations(
      req.userId,
      { limit: Math.min(parseInt(limit, 10) || 10, 50) }
    );
    res.json({ data: communities });
  } catch (err) { next(err); }
}

// GET /api/communities/trending?type=&limit=20
async function getTrending(req, res, next) {
  try {
    const { type, limit = '20' } = req.query;
    const VALID_TYPES = ['fandom', 'work'];
    const communities = await recommendationService.getTrending({
      type:  VALID_TYPES.includes(type) ? type : null,
      limit: Math.min(parseInt(limit, 10) || 20, 50),
    });
    res.json({ data: communities });
  } catch (err) { next(err); }
}

// GET /api/communities/discover?type=
async function getDiscover(req, res, next) {
  try {
    const { type } = req.query;
    const VALID_TYPES = ['fandom', 'work'];
    const result = await recommendationService.getDiscover(req.userId, {
      type: VALID_TYPES.includes(type) ? type : null,
    });
    res.json({ data: result });
  } catch (err) { next(err); }
}

// POST /api/communities/:id/tags  { tags: string[] }
async function setTags(req, res, next) {
  try {
    const { tags } = req.body;
    const cleaned = await recommendationService.setTags(req.params.id, tags || [], req.userId);
    res.json({ data: { tags: cleaned } });
  } catch (err) { next(err); }
}

module.exports = { getRecommendations, getTrending, getDiscover, setTags };
