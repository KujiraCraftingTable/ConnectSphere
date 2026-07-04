const communityService  = require('../services/communityService');
const postService       = require('../services/postService');
const postModel         = require('../models/postModel');
const communityModel    = require('../models/communityModel');
const joinRequestModel  = require('../models/joinRequestModel');

// ── Phase 1 handlers ──────────────────────────────────────────────────────────

// POST /api/communities
async function createCommunity(req, res, next) {
  try {
    const { name, description, type, privacy, icon_emoji, cover_color } = req.body;
    const community = await communityService.createCommunity(req.userId, {
      name, description, type, privacy,
      iconEmoji:  icon_emoji,
      coverColor: cover_color,
    });
    res.status(201).json({ data: community });
  } catch (err) { next(err); }
}

// GET /api/communities?query=&type=&tags=&sort=&limit=&offset=
async function searchCommunities(req, res, next) {
  try {
    const { query, type, tags, sort, limit, offset } = req.query;
    const parsedTags = tags ? tags.split(',').map(t => t.trim()).filter(Boolean) : [];
    const communities = await communityService.searchCommunities({
      query, type, tags: parsedTags, sort, limit, offset,
      requestingUserId: req.userId,
    });
    res.json({ data: communities });
  } catch (err) { next(err); }
}

// GET /api/communities/me
async function getMyCommunities(req, res, next) {
  try {
    const communities = await communityService.getMyCommunities(req.userId);
    res.json({ data: communities });
  } catch (err) { next(err); }
}

// GET /api/communities/:id
async function getCommunity(req, res, next) {
  try {
    const community = await communityService.getCommunityById(req.params.id, req.userId);
    res.json({ data: community });
  } catch (err) { next(err); }
}

// POST /api/communities/:id/join  (P1 — direct join, public communities only)
async function joinCommunity(req, res, next) {
  try {
    await communityService.joinCommunity(req.params.id, req.userId);
    res.json({ status: 'ok', message: 'Joined community' });
  } catch (err) { next(err); }
}

// DELETE /api/communities/:id/leave
async function leaveCommunity(req, res, next) {
  try {
    await communityService.leaveCommunity(req.params.id, req.userId);
    res.json({ status: 'ok', message: 'Left community' });
  } catch (err) { next(err); }
}

// GET /api/communities/:id/members?limit=&offset=
async function getCommunityMembers(req, res, next) {
  try {
    const { limit, offset } = req.query;
    const members = await communityService.getCommunityMembers(
      req.params.id, req.userId, { limit, offset }
    );
    res.json({ data: members });
  } catch (err) { next(err); }
}

// GET /api/communities/:id/posts?limit=&offset=
async function getCommunityPosts(req, res, next) {
  try {
    // Community private → chỉ member mới xem được bài viết
    const community = await communityService.getCommunityById(req.params.id, req.userId);
    if (community.privacy === 'private' && !community.is_member) {
      const err = new Error('You must be a member to view this community');
      err.status = 403;
      return next(err);
    }

    const { limit = '20', offset = '0' } = req.query;
    const posts = await postModel.getPostsByCommunity(req.params.id, {
      limit:            parseInt(limit,  10),
      offset:           parseInt(offset, 10),
      requestingUserId: req.userId,
    });
    res.json({ data: posts });
  } catch (err) { next(err); }
}

// POST /api/communities/:id/posts  (dispatches by post_type)
async function createCommunityPost(req, res, next) {
  try {
    const { content, post_type = 'text', options, endsAt, eventData } = req.body;
    let post;

    if (post_type === 'poll') {
      post = await postService.createPollPost(req.userId, req.params.id, { content, options, endsAt });
    } else if (post_type === 'event') {
      post = await postService.createEventPost(req.userId, req.params.id, { content, eventData });
    } else {
      post = await postService.createPost(req.userId, { content, communityId: req.params.id });
    }

    res.status(201).json({ data: post });
  } catch (err) { next(err); }
}

// DELETE /api/posts/:id  (registered in postRoutes)
async function deletePost(req, res, next) {
  try {
    await postService.deletePost(req.userId, req.params.id);
    res.json({ status: 'ok', message: 'Post deleted' });
  } catch (err) { next(err); }
}

// ── Phase 2 handlers ──────────────────────────────────────────────────────────

// POST /api/communities/:id/request-join
async function requestToJoin(req, res, next) {
  try {
    const result = await communityService.requestToJoin(req.params.id, req.userId);
    res.status(result.status === 'joined' ? 200 : 202).json({ data: result });
  } catch (err) { next(err); }
}

// GET /api/communities/:id/join-requests?limit=&offset=  (admin/mod only)
async function listJoinRequests(req, res, next) {
  try {
    const membership = await communityModel.isMember(req.params.id, req.userId);
    if (!membership || !['admin', 'moderator'].includes(membership.role)) {
      const err = new Error('Only admins and moderators can view join requests');
      err.status = 403;
      return next(err);
    }

    const { limit = '20', offset = '0' } = req.query;
    const requests = await joinRequestModel.getPendingRequests(req.params.id, {
      limit:  parseInt(limit,  10),
      offset: parseInt(offset, 10),
    });
    res.json({ data: requests });
  } catch (err) { next(err); }
}

// PATCH /api/communities/:id/join-requests/:requestId  { status: 'approved'|'rejected' }
async function reviewJoinRequest(req, res, next) {
  try {
    const { status } = req.body;
    const updated = await communityService.reviewJoinRequest(
      req.params.requestId,
      req.userId,
      status
    );
    res.json({ data: updated });
  } catch (err) { next(err); }
}

// POST /api/communities/:id/posts/:postId/pin
async function pinPost(req, res, next) {
  try {
    await communityService.pinPost(req.params.postId, req.params.id, req.userId);
    res.json({ status: 'ok', message: 'Post pinned' });
  } catch (err) { next(err); }
}

// DELETE /api/communities/:id/posts/:postId/pin
async function unpinPost(req, res, next) {
  try {
    await communityService.unpinPost(req.params.postId, req.params.id, req.userId);
    res.json({ status: 'ok', message: 'Post unpinned' });
  } catch (err) { next(err); }
}

// DELETE /api/communities/:id/members/:userId
async function kickMember(req, res, next) {
  try {
    await communityService.kickMember(req.params.id, req.params.userId, req.userId);
    res.json({ status: 'ok', message: 'Member removed' });
  } catch (err) { next(err); }
}

// PATCH /api/communities/:id/members/:userId/role  { role: 'admin'|'moderator'|'member' }
async function updateMemberRole(req, res, next) {
  try {
    const { role } = req.body;
    const result = await communityService.updateMemberRole(
      req.params.id,
      req.params.userId,
      role,
      req.userId
    );
    res.json({ data: result });
  } catch (err) { next(err); }
}

module.exports = {
  // Phase 1
  createCommunity,
  searchCommunities,
  getMyCommunities,
  getCommunity,
  joinCommunity,
  leaveCommunity,
  getCommunityMembers,
  getCommunityPosts,
  createCommunityPost,
  deletePost,
  // Phase 2
  requestToJoin,
  listJoinRequests,
  reviewJoinRequest,
  pinPost,
  unpinPost,
  kickMember,
  updateMemberRole,
};
