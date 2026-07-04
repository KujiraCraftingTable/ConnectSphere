const router      = require('express').Router();
const { listPosts, getPost, analyzePost, createPost, sharePost, softDeletePost, updatePost } = require('../controllers/postsController');
const { authMiddleware } = require('./authRoutes');
const interactions  = require('./interactionRoutes');
const { voteOnPoll } = require('../services/postService');
const { reportPost } = require('../controllers/reportController');

// Toàn bộ post routes yêu cầu JWT — danh tính lấy từ req.userId, không tin body
router.use(authMiddleware);

router.get('/',         listPosts);
router.post('/',        createPost);
router.post('/analyze', analyzePost);
router.get('/:id',      getPost);

// Soft-delete và update — phải đứng trước wildcard interactions
router.delete('/:id', softDeletePost);
router.patch('/:id',  updatePost);

// Phase 2: Poll vote — POST /api/posts/:id/poll/vote  { optionId }
router.post('/:id/poll/vote', async (req, res, next) => {
  try {
    const { optionId } = req.body;
    if (!optionId) {
      const err = new Error('optionId is required');
      err.status = 400;
      return next(err);
    }
    await voteOnPoll(req.params.id, req.userId, optionId);
    res.json({ status: 'ok', message: 'Vote recorded' });
  } catch (err) { next(err); }
});

// Phase 3: Report a post
router.post('/:id/report', reportPost);

// Phase 3: Share/repost a post
router.post('/:id/share', sharePost);

// Like + Comment nested under /:id
router.use('/:id', interactions);

module.exports = router;
