const router = require('express').Router();
const rateLimit = require('express-rate-limit');
const { authMiddleware } = require('./authRoutes');
const { recordClarification } = require('../services/venueLocationService');
const logger = require('../utils/logger');

router.use(authMiddleware);

const MAX_LEN = 100;

// Writing a location alias is a write that affects the whole system (it drives
// search's hard filter), so it gets its own limiter — the global 1000/15min
// limiter wouldn't mean much here.
const clarifyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
});

// POST /api/locations/clarify  { alias, canonical }
// The user confirms right on the warning box that "landmark hcmc" is actually "Landmark 81".
// The backend geocodes the canonical name itself → if geocoding succeeds it's
// validated immediately, otherwise it's left pending for the data controller
// (scripts/review-location-aliases.js) to approve.
router.post('/clarify', clarifyLimiter, async (req, res, next) => {
  try {
    const { alias, canonical } = req.body;

    if (typeof alias !== 'string' || typeof canonical !== 'string' ||
        !alias.trim() || !canonical.trim()) {
      return res.status(400).json({ status: 'error', message: 'alias and canonical are required' });
    }
    if (alias.trim().length > MAX_LEN || canonical.trim().length > MAX_LEN) {
      return res.status(400).json({ status: 'error', message: `alias and canonical must be ${MAX_LEN} characters or fewer` });
    }

    const result = await recordClarification({
      alias:     alias.trim(),
      canonical: canonical.trim(),
      userId:    req.userId,
    });

    res.json({
      status:        'ok',
      resolved:      result.resolved,
      province_name: result.provinceName,
      lat:           result.lat,
      lng:           result.lng,
    });
  } catch (err) {
    logger.warn({ err }, 'Location clarify failed');
    next(err);
  }
});

module.exports = router;
