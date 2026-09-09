const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const { getRecommendations } = require('../controllers/feedController');

router.get('/recommendations', authMiddleware, getRecommendations);

module.exports = router;
