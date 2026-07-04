const postModel        = require('../models/postModel');
const communityModel   = require('../models/communityModel');
const pollModel        = require('../models/pollModel');
const eventModel       = require('../models/eventModel');
const notificationModel = require('../models/notificationModel');
const { scheduleInterestRebuild } = require('./recommendationService');

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// ── Phase 1 ───────────────────────────────────────────────────────────────────

// Create a plain-text community post; verifies membership before inserting
async function createPost(userId, { content, communityId }) {
  if (!content?.trim())            clientError('Post content is required');
  if (content.trim().length > 2000) clientError('Post content must be at most 2000 characters');

  if (communityId) {
    const membership = await communityModel.isMember(communityId, userId);
    if (!membership) clientError('You must be a member of this community to post', 403);
  }

  const post = await postModel.createCommunityPost({
    content:     content.trim(),
    authorId:    userId,
    communityId: communityId || null,
    postType:    'text',
  });

  if (communityId) {
    await communityModel.incrementPostCount(communityId, 1);
    await notificationModel.createBulkNotifications(communityId, 'new_post', post.id, userId);
    scheduleInterestRebuild(userId);
  }

  return post;
}

// Delete a post; only the author, community admin, or moderator may do this
async function deletePost(requesterId, postId) {
  const meta = await postModel.findPostMeta(postId);
  if (!meta) clientError('Post not found', 404);

  const isAuthor = meta.author_id === requesterId;

  let isCommunityStaff = false;
  if (meta.community_id) {
    const membership = await communityModel.isMember(meta.community_id, requesterId);
    isCommunityStaff = ['admin', 'moderator'].includes(membership?.role);
  }

  if (!isAuthor && !isCommunityStaff) {
    clientError('You do not have permission to delete this post', 403);
  }

  const deleted = await postModel.deletePost(postId);
  if (deleted?.community_id) {
    await communityModel.incrementPostCount(deleted.community_id, -1);
  }
}

// ── Phase 2 ───────────────────────────────────────────────────────────────────

// Create a poll post with 2–6 options; notifies all community members
async function createPollPost(authorId, communityId, { content, options, endsAt = null }) {
  if (!content?.trim())             clientError('Post content is required');
  if (content.trim().length > 2000) clientError('Post content must be at most 2000 characters');
  if (!Array.isArray(options) || options.length < 2) clientError('Poll must have at least 2 options');
  if (options.length > 6)           clientError('Poll can have at most 6 options');

  const trimmedOptions = options.map(o => (o || '').trim()).filter(Boolean);
  if (trimmedOptions.length < 2)    clientError('Poll options must not be empty');

  const membership = await communityModel.isMember(communityId, authorId);
  if (!membership) clientError('You must be a member of this community to post', 403);

  if (endsAt && new Date(endsAt) <= new Date()) {
    clientError('Poll end date must be in the future');
  }

  const post = await postModel.createCommunityPost({
    content:     content.trim(),
    authorId,
    communityId,
    postType:    'poll',
  });

  await pollModel.createPollWithOptions(post.id, trimmedOptions, endsAt || null);
  await communityModel.incrementPostCount(communityId, 1);
  await notificationModel.createBulkNotifications(communityId, 'new_post', post.id, authorId);

  return post;
}

// Create an event post; notifies all community members
async function createEventPost(authorId, communityId, { content, eventData }) {
  if (!content?.trim())             clientError('Post content is required');
  if (content.trim().length > 2000) clientError('Post content must be at most 2000 characters');
  if (!eventData?.title?.trim())    clientError('Event title is required');
  if (!eventData?.startsAt)         clientError('Event start time is required');

  const startsAt = new Date(eventData.startsAt);
  if (isNaN(startsAt.getTime()))    clientError('Invalid event start time');
  if (startsAt <= new Date())       clientError('Event start time must be in the future');

  const membership = await communityModel.isMember(communityId, authorId);
  if (!membership) clientError('You must be a member of this community to post', 403);

  const post = await postModel.createCommunityPost({
    content:     content.trim(),
    authorId,
    communityId,
    postType:    'event',
  });

  await eventModel.createEvent(post.id, {
    title:    eventData.title.trim(),
    location: eventData.location?.trim() || null,
    startsAt: eventData.startsAt,
    endsAt:   eventData.endsAt || null,
  });

  await communityModel.incrementPostCount(communityId, 1);
  await notificationModel.createBulkNotifications(communityId, 'new_post', post.id, authorId);

  return post;
}

// Cast a vote on a poll option; enforces membership and one-vote-per-poll
async function voteOnPoll(postId, userId, optionId) {
  const meta = await postModel.findPostMeta(postId);
  if (!meta)                  clientError('Post not found', 404);
  if (meta.post_type !== 'poll') clientError('This post is not a poll', 400);

  if (meta.community_id) {
    const membership = await communityModel.isMember(meta.community_id, userId);
    if (!membership) clientError('You must be a member of this community to vote', 403);
  }

  // Verify the option belongs to this poll
  const pollData = await pollModel.getPollWithVotes(postId, null);
  const validOption = pollData.options.find(o => o.id === optionId);
  if (!validOption) clientError('Invalid poll option for this post', 400);

  await pollModel.voteOnPoll(optionId, userId);
}

// RSVP to an event; enforces community membership
async function rsvpEvent(eventId, userId, status) {
  const VALID = ['going', 'maybe', 'not_going'];
  if (!VALID.includes(status)) clientError('Status must be going, maybe, or not_going');

  const event = await eventModel.getEventById(eventId);
  if (!event) clientError('Event not found', 404);

  if (event.community_id) {
    const membership = await communityModel.isMember(event.community_id, userId);
    if (!membership) clientError('You must be a member of this community to RSVP', 403);
  }

  await eventModel.upsertRsvp(eventId, userId, status);
}

module.exports = { createPost, deletePost, createPollPost, createEventPost, voteOnPoll, rsvpEvent };
