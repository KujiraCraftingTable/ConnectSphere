const postModel = require('../models/postModel');
const postService = require('../services/postService');
const { analyzePostContent } = require('../services/postAnalyzeService');
const { tagQueue }         = require('../queues/tagQueue');
const { enqueuePostEmbed } = require('../queues/embedQueue');
const { deletePostChunks } = require('../services/chunkService');
const { pushUserNotification, actorPayload } = require('../services/userNotifyService');
const { normalizeImageUrls } = require('../utils/postInput');
const { query } = require('../config/db');
const logger = require('../utils/logger');

// GET /api/posts  (auth required — viewer is the user from the JWT)
async function listPosts(req, res, next) {
  try {
    const { mode, author_id, filter, tag, limit = '20', offset = '0' } = req.query;
    const connectionsOnly = filter === 'connections';
    const filters = {
      mode,
      authorId:  author_id,
      viewerId:  req.userId,
      tag:       tag || null,
      connectionsOnly,
      limit:     Math.min(Math.max(parseInt(limit, 10) || 20, 1), 50),
      offset:    Math.max(parseInt(offset, 10) || 0, 0),
    };

    const [posts, total] = await Promise.all([
      postModel.findAll(filters),
      postModel.countAll({ mode, authorId: author_id, viewerId: req.userId, tag: tag || null, connectionsOnly }),
    ]);

    res.json({
      data: posts,
      pagination: { total, limit: filters.limit, offset: filters.offset },
    });
  } catch (err) {
    next(err);
  }
}

// GET /api/posts/:id
async function getPost(req, res, next) {
  try {
    const post = await postModel.findById(req.params.id, req.userId);
    if (!post) {
      const err = new Error('Post not found');
      err.status = 404;
      return next(err);
    }
    res.json({ data: post });
  } catch (err) {
    next(err);
  }
}

// POST /api/posts/analyze
// Body: { content: string, currentMode: "hobby" | "work" }
async function analyzePost(req, res, next) {
  try {
    const { content, currentMode } = req.body;
    if (!content || typeof content !== 'string' || !content.trim()) {
      return res.status(400).json({ error: 'content is required' });
    }

    const result = await analyzePostContent(content.trim());

    // Only warn when confident + mismatched against currentMode
    const isMismatch =
      result.confidence >= 0.75 &&
      result.suggestedMode !== 'neutral' &&
      currentMode &&
      result.suggestedMode !== currentMode;

    res.json({ ...result, isMismatch });
  } catch (err) {
    next(err);
  }
}

// POST /api/posts  (auth required — author is the user from the JWT)
// Body: { content, mode, privacy?, image_url?, link_url?, article_title?,
//         hashtags?, show_ai_tags?, post_type? ('text' | 'poll' | 'event') }
// Poll/event branches mirror communityController.createCommunityPost's
// dispatch pattern, but always pass communityId: null — these are Feed
// posts, so postService.createPollPost/createEventPost skip every
// community-only side effect (membership check, post_count, notifications,
// realtime room broadcast) for them.
async function createPost(req, res, next) {
  try {
    const { content, mode, privacy = 'public', post_type = 'text', options, endsAt, eventData } = req.body;
    const hashtags   = Array.isArray(req.body.hashtags) ? req.body.hashtags : [];
    const showAiTags = !!req.body.show_ai_tags;

    // A Feed post has no community to derive the mode from — require it for
    // every post_type (the text branch below already did; poll/event slipped
    // through and silently defaulted to 'hobby').
    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ error: 'mode must be hobby or work' });
    }

    if (post_type === 'poll') {
      const post = await postService.createPollPost(req.userId, null, {
        content, options, endsAt, mode, privacy, hashtags, showAiTags,
      });
      return res.status(201).json({ data: post });
    }
    if (post_type === 'event') {
      const post = await postService.createEventPost(req.userId, null, {
        content, eventData, mode, privacy, hashtags, showAiTags,
      });
      return res.status(201).json({ data: post });
    }

    // Multiple images: ordered array of URLs, capped at 10 images per post
    const imageUrls = normalizeImageUrls(req.body.image_urls);

    // Content can be empty if the post has a link or images
    const hasContent = content?.trim();
    const hasLink    = req.body.link_url;
    if (!hasContent && !hasLink && !imageUrls) {
      return res.status(400).json({ error: 'content, link_url or image_urls is required' });
    }
    if (typeof content === 'string' && content.length > 2000) {
      return res.status(400).json({ error: 'content must be at most 2000 characters' });
    }

    const post = await postModel.create({
      authorId:     req.userId,
      content:      content?.trim() || null,
      mode,
      privacy,
      imageUrl:     req.body.image_url     || null,
      imageUrls,
      linkUrl:      req.body.link_url      || null,
      articleTitle: req.body.article_title || null,
      hashtags:     Array.isArray(req.body.hashtags) ? req.body.hashtags : [],
      showAiTags:   !!req.body.show_ai_tags,
    });

    // Respond immediately — no blocking on AI
    res.status(201).json({ data: post });

    // Fire-and-forget: mode check + tag extraction run in background
    const postContent = content?.trim() || null;
    runPostBackground(post.id, req.userId, mode, postContent).catch((err) =>
      logger.error({ err, postId: post.id }, 'Background post processing failed')
    );
  } catch (err) {
    next(err);
  }
}

/**
 * Background pipeline after post creation:
 *   - Analyze content to detect mode mismatch → notify user
 *   - Enqueue tag extraction job (BullMQ → Redis)
 */
async function runPostBackground(postId, authorId, postedMode, content) {
  await Promise.allSettled([
    runModeCheck(postId, authorId, postedMode, content),
    content
      ? tagQueue.add('extract', { postId, content }, {
          attempts: 3,
          backoff: { type: 'exponential', delay: 5000 },
          // chunk embed job is chained from tagQueue's completed event
        })
      : enqueuePostEmbed(postId), // link-only post: no tags to extract, embed directly
  ]);
}

async function runModeCheck(postId, authorId, postedMode, content) {
  if (!content) return;
  const result = await analyzePostContent(content);
  const isMismatch =
    result.confidence >= 0.75 &&
    result.suggestedMode !== 'neutral' &&
    result.suggestedMode !== postedMode;

  if (!isMismatch) return;

  // Routed through pushUserNotification so it emits the 'notification' socket
  // event like every other type — writing the row directly meant this one
  // never arrived in realtime.
  await pushUserNotification({
    userId:  authorId,
    type:    'mode_mismatch',
    postId,
    payload: {
      suggestedMode: result.suggestedMode,
      currentMode:   postedMode,
      reason:        result.reason,
    },
  });
  logger.info({ postId, suggestedMode: result.suggestedMode }, 'Mode mismatch notification created');
}

// POST /api/posts/:id/share  (auth required)
// Body: { content?, mode, privacy? } — creates a repost embedding the original post
async function sharePost(req, res, next) {
  try {
    const { content, mode, privacy = 'public' } = req.body;
    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ error: 'mode must be hobby or work' });
    }

    // findById enforces privacy — can only share a post you're allowed to view
    const original = await postModel.findById(req.params.id, req.userId);
    if (!original) {
      const err = new Error('Post not found');
      err.status = 404;
      return next(err);
    }

    // Sharing a share → point to the root post so we don't create nested chains
    const rootId = original.shared_post_id ?? original.id;

    const post = await postModel.create({
      authorId:     req.userId,
      content:      content?.trim() || '',
      mode,
      privacy,
      sharedPostId: rootId,
    });

    await query('UPDATE posts SET share_count = share_count + 1 WHERE id = $1', [rootId]);

    res.status(201).json({ data: post });

    // Notification for the original post's author — fire-and-forget
    (async () => {
      const { rows: [root] } = await query('SELECT author_id FROM posts WHERE id = $1', [rootId]);
      if (root && root.author_id !== req.userId) {
        await pushUserNotification({
          userId:  root.author_id,
          type:    'post_shared',
          postId:  rootId,
          payload: await actorPayload(req.userId),
        });
      }
    })().catch((err) => logger.warn({ err }, 'post_shared notification failed'));
  } catch (err) {
    next(err);
  }
}

// DELETE /api/posts/:id  (auth required)
// Soft-delete: set status = 'deleted' — the post is hidden from the feed but stays in the DB.
// Authorization delegates to postService.deletePost — author-only for Feed
// posts (community_id NULL), author-OR-community-staff (admin/moderator) for
// community posts. Single source of truth, no separate community delete route.
async function softDeletePost(req, res, next) {
  try {
    await postService.deletePost(req.userId, req.params.id);

    // Once a post is hidden, its chunks must also disappear from search/feed
    deletePostChunks(req.params.id)
      .catch((err) => logger.warn({ err, postId: req.params.id }, 'softDelete: chunk cleanup failed'));

    res.json({ status: 'ok', message: 'Post deleted' });
  } catch (err) {
    next(err);
  }
}

// GET /api/posts/deleted  (auth required)
// List of the current user's own soft-deleted posts, newest first — "Recently
// Deleted" list. Same shape as every other post-returning endpoint (buildPostSelect).
async function listDeletedPosts(req, res, next) {
  try {
    const limit  = Math.min(Math.max(parseInt(req.query.limit  || '20', 10) || 20, 1), 50);
    const offset = Math.max(parseInt(req.query.offset || '0', 10) || 0, 0);

    const posts = await postModel.listDeletedPosts(req.userId, { limit, offset });
    res.json({ data: posts, pagination: { limit, offset } });
  } catch (err) {
    next(err);
  }
}

// GET /api/posts/saved  (auth required)
// List of the current user's own saved (bookmarked) posts, most recently saved first.
// Same shape as every other post-returning endpoint (buildPostSelect); privacy/block
// is re-filtered in postModel.listSavedPosts so a saved post whose author later
// changes privacy or blocks the viewer won't leak through.
async function listSavedPosts(req, res, next) {
  try {
    const limit  = Math.min(Math.max(parseInt(req.query.limit  || '20', 10) || 20, 1), 50);
    const offset = Math.max(parseInt(req.query.offset || '0', 10) || 0, 0);

    const posts = await postModel.listSavedPosts(req.userId, { limit, offset });
    res.json({ data: posts, pagination: { limit, offset } });
  } catch (err) {
    next(err);
  }
}

// POST /api/posts/:id/restore  (auth required)
// Restore a soft-deleted post — author only (not extended to community
// staff, see postService.restorePost). The inverse of softDeletePost.
async function restorePost(req, res, next) {
  try {
    const post = await postService.restorePost(req.userId, req.params.id);
    res.json({ data: post });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/posts/:id  (auth required)
// Update a post's content, privacy, and images
async function updatePost(req, res, next) {
  try {
    const post = await postModel.findPostMeta(req.params.id);
    if (!post) {
      const err = new Error('Post not found');
      err.status = 404;
      return next(err);
    }
    if (post.author_id !== req.userId) {
      const err = new Error('Forbidden');
      err.status = 403;
      return next(err);
    }

    const { content, privacy, image_url, image_urls, link_url, article_title } = req.body;

    let imageUrls = null;
    if (Array.isArray(image_urls)) {
      imageUrls = image_urls
        .filter((u) => typeof u === 'string' && u.trim())
        .slice(0, 10);
      if (imageUrls.length === 0) imageUrls = null;
    }

    // Distinguish "content field not sent at all" (leave the existing caption
    // alone) from "content field explicitly sent as empty string" (the user
    // deleted all their text and wants that saved) — a plain `content?.trim() ||
    // null` collapses both cases to null, so postModel's COALESCE kept the OLD
    // caption even when the user intentionally cleared it. contentProvided tells
    // the model which behavior applies.
    const contentProvided = req.body.content !== undefined;
    const trimmedContent = contentProvided ? (content ?? '').trim() : null;

    const updated = await postModel.updatePost(req.params.id, {
      content:          trimmedContent,
      contentProvided,
      privacy:          privacy              || null,
      imageUrl:         image_url            || null,
      imageUrls,
      linkUrl:          link_url             || null,
      articleTitle:     article_title        || null,
    });

    if (updated === 'empty') {
      const err = new Error('A post must have a caption, image, or link');
      err.status = 400;
      return next(err);
    }

    if (!updated) {
      const err = new Error('Post not found or already deleted');
      err.status = 404;
      return next(err);
    }

    // Content changed → re-embed the chunk with the new text (tags stay unchanged)
    enqueuePostEmbed(req.params.id)
      .catch((err) => logger.warn({ err, postId: req.params.id }, 'updatePost: enqueue embed failed'));

    res.json({ data: updated });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listPosts, getPost, analyzePost, createPost, sharePost, softDeletePost, updatePost,
  listDeletedPosts, restorePost, listSavedPosts,
};
