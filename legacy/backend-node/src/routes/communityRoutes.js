const router = require('express').Router();
const { authMiddleware } = require('./authRoutes');
const ctrl       = require('../controllers/communityController');
const reportCtrl = require('../controllers/reportController');
const analyticsCtrl    = require('../controllers/analyticsController');
const recCtrl    = require('../controllers/recommendationController');

// All community routes require a valid JWT
router.use(authMiddleware);

// ── Static routes MUST be declared before /:id ────────────────────────────────
router.get('/me',              ctrl.getMyCommunities);

// Phase 3: discovery routes (before /:id to avoid UUID conflicts)
router.get('/recommendations', recCtrl.getRecommendations);
router.get('/trending',        recCtrl.getTrending);
router.get('/discover',        recCtrl.getDiscover);

// ── General search / create ───────────────────────────────────────────────────
router.post('/',  ctrl.createCommunity);
router.get('/',   ctrl.searchCommunities);   // P3: now supports ?tags=&sort=
router.get('/:id', ctrl.getCommunity);

// ── Phase 1: membership ───────────────────────────────────────────────────────
router.post('/:id/join',    ctrl.joinCommunity);
router.delete('/:id/leave', ctrl.leaveCommunity);
router.get('/:id/members',  ctrl.getCommunityMembers);

// ── Phase 1: posts ────────────────────────────────────────────────────────────
router.get('/:id/posts',  ctrl.getCommunityPosts);
router.post('/:id/posts', ctrl.createCommunityPost);

// ── Phase 2: join requests ────────────────────────────────────────────────────
router.post('/:id/request-join',              ctrl.requestToJoin);
router.get('/:id/join-requests',              ctrl.listJoinRequests);
router.patch('/:id/join-requests/:requestId', ctrl.reviewJoinRequest);

// ── Phase 2: pin / unpin ──────────────────────────────────────────────────────
router.post('/:id/posts/:postId/pin',   ctrl.pinPost);
router.delete('/:id/posts/:postId/pin', ctrl.unpinPost);

// ── Phase 2: member management ────────────────────────────────────────────────
router.delete('/:id/members/:userId',      ctrl.kickMember);
router.patch('/:id/members/:userId/role',  ctrl.updateMemberRole);

// ── Phase 3: reports / moderation ────────────────────────────────────────────
router.post('/:id/members/:userId/report',   reportCtrl.reportMember);
router.get('/:id/moderation',                reportCtrl.getModerationQueue);
router.patch('/:id/reports/:reportId',       reportCtrl.resolveReport);

// ── Phase 3: analytics ───────────────────────────────────────────────────────
router.get('/:id/analytics', analyticsCtrl.getAnalytics);

// ── Phase 3: tags ────────────────────────────────────────────────────────────
router.post('/:id/tags', recCtrl.setTags);

module.exports = router;
