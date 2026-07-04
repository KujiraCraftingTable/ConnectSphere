const router = require('express').Router();
const { authMiddleware }  = require('./authRoutes');
const { aiSearchHandler } = require('../controllers/searchController');
const { lookupEntity }    = require('../services/entityLookupService');
const { getSuggestions }  = require('../services/suggestionService');

// Toàn bộ search routes yêu cầu JWT
router.use(authMiddleware);

router.post('/ai', aiSearchHandler);

// GET /api/search/suggestions?mode=friend|colleague
router.get('/suggestions', async (req, res, next) => {
  try {
    const { mode } = req.query;
    const suggestions = await getSuggestions(mode ?? null);
    res.json({ suggestions });
  } catch (err) {
    next(err);
  }
});

// Test endpoint: POST /api/search/lookup  { "text": "KNY", "category": "Anime" }
router.post('/lookup', async (req, res, next) => {
  try {
    const { text, category } = req.body;
    if (!text) return res.status(400).json({ error: 'text is required' });
    const result = await lookupEntity(text, category || null);
    res.json(result);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
