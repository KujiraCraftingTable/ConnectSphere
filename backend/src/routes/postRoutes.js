const router      = require('express').Router();
const {
  listPosts, getPost, analyzePost, createPost, sharePost, softDeletePost, updatePost,
  listDeletedPosts, restorePost, listSavedPosts,
} = require('../controllers/postsController');
const { authMiddleware } = require('./authRoutes');
const interactions  = require('./interactionRoutes');
const { voteOnPoll } = require('../services/postService');
const { reportPost } = require('../controllers/reportController');
const { query } = require('../config/db');

// All post routes require a JWT — identity comes from req.userId, never trust the body
router.use(authMiddleware);

router.get('/',         listPosts);
router.post('/',        createPost);
router.post('/analyze', analyzePost);

// Delete-recovery: "my recently-deleted posts" — must be registered before
// the wildcard '/:id' route below, same ordering concern as communityRoutes.js's
// '/me' route (registered before its own '/:id'), otherwise Express would
// match '/deleted' as { id: 'deleted' } and hit getPost instead.
router.get('/deleted', listDeletedPosts);

// Saved/bookmarked posts: "my saved posts" — same wildcard-shadowing concern
// as '/deleted' above, must be registered before '/:id'.
router.get('/saved', listSavedPosts);

// Delete-recovery: "my recently-deleted comments", across ALL posts — not
// scoped to one post id, so it can't live nested inside interactionRoutes.js
// (mounted per-post at '/:id'). Raw-SQL-inline here, same convention
// interactionRoutes.js already uses for comment queries. Registered before
// '/:id' for the same shadowing reason as '/deleted' above (defensive; in
// practice '/comments/deleted' is two path segments so '/:id' alone would
// never match it, but keeping every "my X" listing above the wildcard block
// keeps route ordering easy to reason about at a glance).
router.get('/comments/deleted', async (req, res, next) => {
  try {
    const limit  = Math.min(Math.max(parseInt(req.query.limit  || '20', 10) || 20, 1), 50);
    const offset = Math.max(parseInt(req.query.offset || '0', 10) || 0, 0);

    const { rows } = await query(
      `SELECT c.id, c.post_id, c.content, c.created_at, c.deleted_at, c.parent_comment_id, c.like_count
       FROM comments c
       WHERE c.author_id = $1 AND c.status = 'deleted'
       ORDER BY c.deleted_at DESC
       LIMIT $2 OFFSET $3`,
      [req.userId, limit, offset]
    );

    res.json({ data: rows, pagination: { limit, offset } });
  } catch (err) { next(err); }
});

router.get('/:id',      getPost);

// Soft-delete and update — must be registered before the wildcard interactions
router.delete('/:id',  softDeletePost);
router.patch('/:id',   updatePost);
router.post('/:id/restore', restorePost);

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
