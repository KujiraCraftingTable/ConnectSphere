const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const { rsvpEvent } = require('../services/postService');

// POST /api/events/:id/rsvp  { status: 'going'|'maybe'|'not_going' }
router.post('/:id/rsvp', authMiddleware, async (req, res, next) => {
  try {
    const { status } = req.body;
    await rsvpEvent(req.params.id, req.userId, status);
    res.json({ status: 'ok', message: 'RSVP recorded' });
  } catch (err) { next(err); }
});

module.exports = router;
