const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const { saveAlias } = require('../services/entityLookupService');
const logger = require('../utils/logger');

router.use(authMiddleware);

// POST /api/entities/alias  { keyword, entity_id }
// User xác nhận "keyword vừa search thuộc canonical này" → lưu alias để Tier-1 bắt lần sau.
router.post('/alias', async (req, res, next) => {
  try {
    const { keyword, entity_id } = req.body;
    if (!keyword?.trim() || !entity_id) {
      return res.status(400).json({ status: 'error', message: 'keyword and entity_id are required' });
    }

    const entity = await saveAlias(keyword.trim(), entity_id);
    if (!entity) {
      return res.status(404).json({ status: 'error', message: 'Entity not found' });
    }

    logger.info({ keyword, entityId: entity_id, canonical: entity.canonical_name }, 'Alias confirmed by user');
    res.json({ status: 'ok', canonical_name: entity.canonical_name });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
