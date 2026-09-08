const postModel        = require('../models/postModel');
const communityModel   = require('../models/communityModel');
const pollModel        = require('../models/pollModel');
const eventModel       = require('../models/eventModel');
const notifyService = require('./userNotifyService');
const { scheduleInterestRebuild } = require('./recommendationService');
const { emitToRoom } = require('../utils/realtime');
const { tagQueue } = require('../queues/tagQueue');
const logger = require('../utils/logger');

// Fire-and-forget AI tag extraction for a community post — same queue/options
// as Feed's postsController.runPostBackground, just triggered from here since
// community post creation has no controller-level "respond, then background
// work" split (this service call is fully awaited before the controller
// responds). Never awaited by the caller, so it cannot delay the response;
// failures are logged, not thrown. Closes the "community posts get zero AI
// tags" gap — previously this queue was only wired into Feed.
function enqueueTagExtraction(postId, content) {
  if (!content) return;
  tagQueue
    .add('extract', { postId, content }, {
      attempts: 3,
      backoff: { type: 'exponential', delay: 5000 },
    })
    .catch((err) => logger.error({ err, postId }, 'Community tag extraction enqueue failed'));
}

// Notify every community member except the author that a new post landed.
// Grouped by community (not by post) so a busy community collapses into a
// single "3 new posts in Hiking" row rather than flooding the inbox.
// The community name is resolved by a JOIN at read time, so it is deliberately
// not snapshotted here — a rename must not leave stale names in every inbox.
async function notifyCommunityOfNewPost(communityId, post, authorId, postType, content) {
  await notifyService.fanOutCommunityNotification({
    communityId,
    type:          'new_post',
    actorId:       authorId,
    excludeUserId: authorId,
    postId:        post.id,
    entityId:      post.id,
    payload: {
      communityId,
      postType,
      postExcerpt: (content ?? '').trim().slice(0, 120) || null,
    },
  });
}

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Same rule postsController.createPost's text-post path already enforces —
// reused here so poll/event posts (community or Feed) validate `mode`
// identically. `mode` is optional (community callers never pass it, letting
// postModel.createCommunityPost fall back to the community-derived mode), so
// only validate when actually provided.
function validateMode(mode) {
  if (mode != null && !['hobby', 'work'].includes(mode)) {
    clientError('mode must be hobby or work');
  }
}

// ── Phase 1 ───────────────────────────────────────────────────────────────────

// Create a plain-text community post; verifies membership before inserting.
// Content may be empty if the post carries a link or images (same rule as
// Feed's createPost) — imageUrls/linkUrl/articleTitle mirror Feed's shape
// exactly so a community post is indistinguishable from a Feed post.
async function createPost(userId, { content, communityId, imageUrls = null, linkUrl = null, articleTitle = null, hashtags = [], showAiTags = false, mode = null, privacy = null }) {
  const hasContent = content?.trim();
  if (!hasContent && !linkUrl && !imageUrls) {
    clientError('Post content, link_url or image_urls is required');
  }
  if (hasContent && content.trim().length > 2000) {
    clientError('Post content must be at most 2000 characters');
  }
  validateMode(mode);

  if (communityId) {
    const membership = await communityModel.isMember(communityId, userId);
    if (!membership) clientError('You must be a member of this community to post', 403);
  }

  const trimmedContent = content?.trim() || null;
  const post = await postModel.createCommunityPost({
    content:      trimmedContent,
    authorId:     userId,
    communityId:  communityId || null,
    postType:     'text',
    imageUrls,
    linkUrl,
    articleTitle,
    hashtags,
    showAiTags,
    mode,
    privacy,
  });

  enqueueTagExtraction(post.id, trimmedContent);

  if (communityId) {
    await communityModel.incrementPostCount(communityId, 1);
    await notifyCommunityOfNewPost(communityId, post, userId, 'text', trimmedContent);
    scheduleInterestRebuild(userId);
    // Room-only broadcast — no per-member fan-out, open viewers of the
    // community's post list pick this up live. Same shape createCommunityPost
    // already returns (buildPostSelect's columns), plus community_id since
    // that column isn't part of buildPostSelect's own SELECT list.
    emitToRoom(`community:${communityId}`, 'community_post_created', { ...post, community_id: communityId });
  }

  return post;
}

// Delete a post; only the author, community admin, or moderator may do this.
// Single authorization path for DELETE /api/posts/:id — used for both Feed
// posts (author-only, since community_id is null → isCommunityStaff stays
// false) and community posts (author OR staff). Soft-deletes (status =
// 'deleted') to match Feed's existing delete semantics — the row stays for
// referential integrity (comments/likes/pins) instead of being hard-deleted.
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

  const deleted = await postModel.softDeletePost(postId);
  if (!deleted) clientError('Post not found or already deleted', 404);

  if (meta.community_id) {
    await communityModel.incrementPostCount(meta.community_id, -1);
  }

  return deleted;
}

// Restore a soft-deleted post — author-only, unlike deletePost's broader
// author-OR-community-staff authorization (this plan deliberately keeps
// restore simple: only the person who deleted it can bring it back). Checked
// here (via findPostMeta) to give a proper 403 (exists, not yours) vs 404
// (doesn't exist) response; the actual write is still a single atomic
// `UPDATE ... WHERE author_id = $2 AND status = 'deleted'` in
// postModel.restorePost, so authorization can never be bypassed by a race
// between this check and the write. Symmetric with deletePost: re-increments
// communities.post_count when the post belongs to one (deletePost decrements
// it on the way out).
async function restorePost(requesterId, postId) {
  const meta = await postModel.findPostMeta(postId);
  if (!meta) clientError('Post not found', 404);

  if (meta.author_id !== requesterId) {
    clientError('You do not have permission to restore this post', 403);
  }

  const restored = await postModel.restorePost(postId, requesterId);
  if (!restored) clientError('Post not found or not deleted', 404);

  if (meta.community_id) {
    await communityModel.incrementPostCount(meta.community_id, 1);
  }

  return restored;
}

// ── Phase 2 ───────────────────────────────────────────────────────────────────

// Create a poll post with 2–6 options; notifies all community members.
// `communityId` is null for a Feed poll — every community-only side effect
// (membership check, post_count bump, bulk notifications, realtime room
// broadcast) is skipped in that case, mirroring createPost's existing guard.
async function createPollPost(authorId, communityId, { content, options, endsAt = null, hashtags = [], showAiTags = false, mode = null, privacy = null }) {
  if (!content?.trim())             clientError('Post content is required');
  if (content.trim().length > 2000) clientError('Post content must be at most 2000 characters');
  if (!Array.isArray(options) || options.length < 2) clientError('Poll must have at least 2 options');
  if (options.length > 6)           clientError('Poll can have at most 6 options');
  validateMode(mode);

  const trimmedOptions = options.map(o => (o || '').trim()).filter(Boolean);
  if (trimmedOptions.length < 2)    clientError('Poll options must not be empty');

  if (communityId) {
    const membership = await communityModel.isMember(communityId, authorId);
    if (!membership) clientError('You must be a member of this community to post', 403);
  }

  if (endsAt && new Date(endsAt) <= new Date()) {
    clientError('Poll end date must be in the future');
  }

  const post = await postModel.createCommunityPost({
    content:     content.trim(),
    authorId,
    communityId,
    postType:    'poll',
    hashtags,
    showAiTags,
    mode,
    privacy,
  });

  enqueueTagExtraction(post.id, content.trim());

  await pollModel.createPollWithOptions(post.id, trimmedOptions, endsAt || null);

  // Re-fetch AFTER the options exist so poll_data.options isn't null in the
  // response (`post` was fetched before createPollWithOptions ran).
  const fullPost = await postModel.findById(post.id, authorId);

  if (communityId) {
    await communityModel.incrementPostCount(communityId, 1);
    await notifyCommunityOfNewPost(communityId, post, authorId, 'poll', content);
    emitToRoom(`community:${communityId}`, 'community_post_created', { ...fullPost, community_id: communityId });
  }

  return fullPost;
}

// Create an event post; notifies all community members. `communityId` null
// for a Feed event — same community-only-side-effect guard as createPollPost.
async function createEventPost(authorId, communityId, { content, eventData, hashtags = [], showAiTags = false, mode = null, privacy = null }) {
  if (!content?.trim())             clientError('Post content is required');
  if (content.trim().length > 2000) clientError('Post content must be at most 2000 characters');
  if (!eventData?.title?.trim())    clientError('Event title is required');
  if (!eventData?.startsAt)         clientError('Event start time is required');
  validateMode(mode);

  const startsAt = new Date(eventData.startsAt);
  if (isNaN(startsAt.getTime()))    clientError('Invalid event start time');
  if (startsAt <= new Date())       clientError('Event start time must be in the future');

  if (communityId) {
    const membership = await communityModel.isMember(communityId, authorId);
    if (!membership) clientError('You must be a member of this community to post', 403);
  }

  const post = await postModel.createCommunityPost({
    content:     content.trim(),
    authorId,
    communityId,
    postType:    'event',
    hashtags,
    showAiTags,
    mode,
    privacy,
  });

  enqueueTagExtraction(post.id, content.trim());

  await eventModel.createEvent(post.id, {
    title:    eventData.title.trim(),
    location: eventData.location?.trim() || null,
    startsAt: eventData.startsAt,
    endsAt:   eventData.endsAt || null,
  });

  // Re-fetch AFTER the event row exists so event_data isn't null in the response.
  const fullPost = await postModel.findById(post.id, authorId);

  if (communityId) {
    await communityModel.incrementPostCount(communityId, 1);
    await notifyCommunityOfNewPost(communityId, post, authorId, 'event', content);
    emitToRoom(`community:${communityId}`, 'community_post_created', { ...fullPost, community_id: communityId });
  }

  return fullPost;
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

module.exports = { createPost, deletePost, restorePost, createPollPost, createEventPost, voteOnPoll, rsvpEvent };
