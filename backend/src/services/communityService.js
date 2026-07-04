const communityModel         = require('../models/communityModel');
const notificationModel      = require('../models/notificationModel');
const joinRequestModel       = require('../models/joinRequestModel');
const { scheduleInterestRebuild } = require('./recommendationService');

const VALID_TYPES   = ['fandom', 'work'];
const VALID_PRIVACY = ['public', 'private'];
const VALID_ROLES   = ['admin', 'moderator', 'member'];

// Throw a 4xx error with a given status code
function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Validate community name: 3-100 characters
function validateName(name) {
  if (!name || typeof name !== 'string' || !name.trim()) clientError('Community name is required');
  if (name.trim().length < 3)   clientError('Community name must be at least 3 characters');
  if (name.trim().length > 100) clientError('Community name must be at most 100 characters');
}

// ── Phase 1 ───────────────────────────────────────────────────────────────────

// Create a community and add the creator as admin in one logical operation
async function createCommunity(creatorId, { name, description, type, privacy, iconEmoji, coverColor }) {
  validateName(name);
  if (!VALID_TYPES.includes(type))    clientError('type must be fandom or work');
  if (privacy && !VALID_PRIVACY.includes(privacy)) clientError('privacy must be public or private');
  if (description && description.length > 500) clientError('Description must be at most 500 characters');

  let community;
  try {
    community = await communityModel.createCommunity({
      name: name.trim(),
      description: description?.trim() || null,
      type,
      privacy:    privacy    || 'public',
      iconEmoji:  iconEmoji  || '👥',
      coverColor: coverColor || '#7F5AF0',
      createdBy:  creatorId,
    });
  } catch (err) {
    if (err.code === '23505') clientError('A community with this name already exists', 409);
    throw err;
  }

  await communityModel.joinCommunity(community.id, creatorId, 'admin');
  await communityModel.incrementMemberCount(community.id, 1);
  return community;
}

// Search public communities; supports ?tags, ?sort (members | newest | trending)
async function searchCommunities({ query: searchQuery = '', type, tags = [], sort, limit = 20, offset = 0, requestingUserId = null }) {
  const parsedLimit  = Math.min(parseInt(limit,  10) || 20, 50);
  const parsedOffset = parseInt(offset, 10) || 0;
  const validType    = VALID_TYPES.includes(type) ? type : null;
  const validSort    = ['members', 'newest', 'trending'].includes(sort) ? sort : 'members';
  return communityModel.searchCommunities({
    searchQuery,
    type:             validType,
    tags:             Array.isArray(tags) ? tags : [],
    sort:             validSort,
    limit:            parsedLimit,
    offset:           parsedOffset,
    requestingUserId,
  });
}

// Communities the requesting user has already joined
async function getMyCommunities(userId) {
  return communityModel.getCommunitiesByUser(userId);
}

// Single community with isMember/role info for the requesting user
async function getCommunityById(communityId, requestingUserId) {
  const community = await communityModel.getCommunityById(communityId, requestingUserId);
  if (!community) clientError('Community not found', 404);
  return community;
}

// Join a public community (throws if banned or already a member)
async function joinCommunity(communityId, userId) {
  const community = await communityModel.getCommunityById(communityId);
  if (!community) clientError('Community not found', 404);

  if (await communityModel.isBanned(communityId, userId)) {
    clientError('You are banned from this community', 403);
  }

  const existing = await communityModel.isMember(communityId, userId);
  if (existing) clientError('You are already a member of this community', 409);

  await communityModel.joinCommunity(communityId, userId);
  await communityModel.incrementMemberCount(communityId, 1);
  scheduleInterestRebuild(userId);
}

// Leave a community (sole admin cannot leave)
async function leaveCommunity(communityId, userId) {
  const membership = await communityModel.isMember(communityId, userId);
  if (!membership) clientError('You are not a member of this community');

  if (membership.role === 'admin') {
    const allMembers = await communityModel.getCommunityMembers(communityId, { limit: 500, offset: 0 });
    const adminCount = allMembers.filter(m => m.role === 'admin').length;
    if (adminCount <= 1) clientError('You are the sole admin — transfer the role before leaving');
  }

  await communityModel.leaveCommunity(communityId, userId);
  await communityModel.incrementMemberCount(communityId, -1);
  scheduleInterestRebuild(userId);
}

// Paginated list of members for a community.
// Community private → chỉ member mới xem được danh sách thành viên.
async function getCommunityMembers(communityId, requesterId, { limit = 20, offset = 0 } = {}) {
  const community = await communityModel.getCommunityById(communityId);
  if (!community) clientError('Community not found', 404);

  if (community.privacy === 'private') {
    const membership = await communityModel.isMember(communityId, requesterId);
    if (!membership) clientError('You must be a member to view the member list', 403);
  }

  return communityModel.getCommunityMembers(communityId, {
    limit:  parseInt(limit,  10) || 20,
    offset: parseInt(offset, 10) || 0,
  });
}

// ── Phase 2 ───────────────────────────────────────────────────────────────────

// Join or request-to-join a community based on its privacy setting
async function requestToJoin(communityId, userId) {
  const community = await communityModel.getCommunityById(communityId);
  if (!community) clientError('Community not found', 404);

  const existing = await communityModel.isMember(communityId, userId);
  if (existing)  clientError('You are already a member of this community', 409);

  // Ban check phải đứng trước cả nhánh public — user bị ban không được rejoin
  if (await communityModel.isBanned(communityId, userId)) {
    clientError('You are banned from this community', 403);
  }

  // Public → join immediately (same as P1 joinCommunity)
  if (community.privacy === 'public') {
    await communityModel.joinCommunity(communityId, userId);
    await communityModel.incrementMemberCount(communityId, 1);
    return { status: 'joined' };
  }

  // Private → create a pending join request
  const existingReq = await joinRequestModel.hasExistingRequest(communityId, userId);
  if (existingReq) {
    if (existingReq.status === 'pending')  clientError('You already have a pending request', 409);
    if (existingReq.status === 'rejected') clientError('Your previous request was rejected — contact an admin', 403);
    if (existingReq.status === 'approved') clientError('You are already a member of this community', 409);
  }

  const request = await joinRequestModel.createRequest(communityId, userId);

  // Notify admins and moderators (small group — loop is acceptable)
  const allMembers = await communityModel.getCommunityMembers(communityId, { limit: 500, offset: 0 });
  const staff = allMembers.filter(m => ['admin', 'moderator'].includes(m.role));
  for (const person of staff) {
    await notificationModel.createNotification({
      communityId,
      userId:  person.id,
      type:    'join_request',
      refId:   request.id,
    });
  }

  return { status: 'pending', requestId: request.id };
}

// Approve or reject a join request; approving triggers joinCommunity + notification
async function reviewJoinRequest(requestId, reviewerId, status) {
  if (!['approved', 'rejected'].includes(status)) clientError('status must be approved or rejected');

  const request = await joinRequestModel.getRequestById(requestId);
  if (!request) clientError('Request not found', 404);
  if (request.status !== 'pending') clientError('This request has already been reviewed', 409);

  const membership = await communityModel.isMember(request.community_id, reviewerId);
  if (!membership || !['admin', 'moderator'].includes(membership.role)) {
    clientError('Only admins and moderators can review requests', 403);
  }

  const updated = await joinRequestModel.reviewRequest(requestId, reviewerId, status);

  if (status === 'approved') {
    await communityModel.joinCommunity(request.community_id, request.user_id);
    await communityModel.incrementMemberCount(request.community_id, 1);
    scheduleInterestRebuild(request.user_id);
  }

  // Notify the requester of the outcome
  await notificationModel.createNotification({
    communityId: request.community_id,
    userId:      request.user_id,
    type:        status === 'approved' ? 'join_approved' : 'join_rejected',
    refId:       requestId,
  });

  return updated;
}

// Pin a post; only admin or moderator may pin; auto-unpins the previous pinned post
async function pinPost(postId, communityId, requesterId) {
  const membership = await communityModel.isMember(communityId, requesterId);
  if (!membership || !['admin', 'moderator'].includes(membership.role)) {
    clientError('Only admins and moderators can pin posts', 403);
  }

  const result = await communityModel.pinPost(postId, communityId, requesterId);
  if (!result) clientError('Post not found in this community', 404);

  // Notify all community members
  await notificationModel.createBulkNotifications(communityId, 'pinned_post', postId, requesterId);

  return result;
}

// Unpin a post; only admin or moderator may unpin
async function unpinPost(postId, communityId, requesterId) {
  const membership = await communityModel.isMember(communityId, requesterId);
  if (!membership || !['admin', 'moderator'].includes(membership.role)) {
    clientError('Only admins and moderators can unpin posts', 403);
  }

  const result = await communityModel.unpinPost(postId, communityId);
  if (!result) clientError('Post not found or not pinned', 404);
  return result;
}

// Kick a member from a community; enforces role hierarchy
async function kickMember(communityId, targetUserId, requesterId) {
  if (targetUserId === requesterId) clientError('You cannot remove yourself');

  const requester = await communityModel.isMember(communityId, requesterId);
  if (!requester || !['admin', 'moderator'].includes(requester.role)) {
    clientError('Only admins and moderators can remove members', 403);
  }

  const target = await communityModel.isMember(communityId, targetUserId);
  if (!target) clientError('User is not a member of this community', 404);

  // Moderators may only kick regular members
  if (requester.role === 'moderator' && target.role !== 'member') {
    clientError('Moderators can only remove regular members', 403);
  }
  // Only admins can remove admins
  if (target.role === 'admin' && requester.role !== 'admin') {
    clientError('Only admins can remove other admins', 403);
  }

  await communityModel.kickMember(communityId, targetUserId);
  await communityModel.incrementMemberCount(communityId, -1);
}

// Change a member's role; only admins may do this
async function updateMemberRole(communityId, targetUserId, newRole, requesterId) {
  if (!VALID_ROLES.includes(newRole)) clientError('Invalid role');

  const requester = await communityModel.isMember(communityId, requesterId);
  if (!requester || requester.role !== 'admin') {
    clientError('Only admins can change member roles', 403);
  }

  const target = await communityModel.isMember(communityId, targetUserId);
  if (!target) clientError('User is not a member of this community', 404);

  const result = await communityModel.updateMemberRole(communityId, targetUserId, newRole);

  await notificationModel.createNotification({
    communityId,
    userId: targetUserId,
    type:   'role_changed',
    refId:  null,
  });

  return result;
}

module.exports = {
  createCommunity,
  searchCommunities,
  getMyCommunities,
  getCommunityById,
  joinCommunity,
  leaveCommunity,
  getCommunityMembers,
  // Phase 2
  requestToJoin,
  reviewJoinRequest,
  pinPost,
  unpinPost,
  kickMember,
  updateMemberRole,
};
