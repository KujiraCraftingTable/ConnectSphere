const postModel = require('../models/postModel');
const { analyzePostContent } = require('../services/postAnalyzeService');
const { tagQueue }         = require('../queues/tagQueue');
const { enqueuePostEmbed } = require('../queues/embedQueue');
const { deletePostChunks } = require('../services/chunkService');
const userNotifModel = require('../models/userNotificationModel');
const { pushUserNotification, actorPayload } = require('../services/userNotifyService');
const { query } = require('../config/db');
const logger = require('../utils/logger');

// GET /api/posts  (auth required — viewer là user trong JWT)
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

    // Chỉ cảnh báo khi confident + mismatch với currentMode
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

// POST /api/posts  (auth required — author là user trong JWT)
// Body: { content, mode, privacy?, image_url?, link_url?, article_title? }
async function createPost(req, res, next) {
  try {
    const { content, mode, privacy = 'public' } = req.body;

    // Nhiều ảnh: mảng URL có thứ tự, cap 10 ảnh/bài
    let imageUrls = null;
    if (Array.isArray(req.body.image_urls)) {
      imageUrls = req.body.image_urls
        .filter((u) => typeof u === 'string' && u.trim())
        .slice(0, 10);
      if (imageUrls.length === 0) imageUrls = null;
    }

    // Content có thể rỗng nếu post có link hoặc ảnh
    const hasContent = content?.trim();
    const hasLink    = req.body.link_url;
    if (!hasContent && !hasLink && !imageUrls) {
      return res.status(400).json({ error: 'content, link_url or image_urls is required' });
    }
    if (!['hobby', 'work'].includes(mode))
      return res.status(400).json({ error: 'mode must be hobby or work' });

    const post = await postModel.create({
      authorId:     req.userId,
      content:      content?.trim() || null,
      mode,
      privacy,
      imageUrl:     req.body.image_url     || null,
      imageUrls,
      linkUrl:      req.body.link_url      || null,
      articleTitle: req.body.article_title || null,
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

  await userNotifModel.createNotification({
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
// Body: { content?, mode, privacy? } — tạo bài repost nhúng bài gốc
async function sharePost(req, res, next) {
  try {
    const { content, mode, privacy = 'public' } = req.body;
    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ error: 'mode must be hobby or work' });
    }

    // findById enforce privacy — chỉ share được bài mình có quyền xem
    const original = await postModel.findById(req.params.id, req.userId);
    if (!original) {
      const err = new Error('Post not found');
      err.status = 404;
      return next(err);
    }

    // Share một bài share → trỏ về bài gốc để không tạo chuỗi lồng nhau
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

    // Notification cho tác giả bài gốc — fire-and-forget
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
// Soft-delete: set status = 'deleted' — bài viết ẩn khỏi feed nhưng vẫn còn trong DB
async function softDeletePost(req, res, next) {
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

    const deleted = await postModel.softDeletePost(req.params.id);
    if (!deleted) {
      const err = new Error('Post not found or already deleted');
      err.status = 404;
      return next(err);
    }

    // Bài đã ẩn thì chunk cũng phải biến mất khỏi search/feed
    deletePostChunks(req.params.id)
      .catch((err) => logger.warn({ err, postId: req.params.id }, 'softDelete: chunk cleanup failed'));

    res.json({ status: 'ok', message: 'Post deleted' });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/posts/:id  (auth required)
// Cập nhật nội dung, privacy, ảnh của bài viết
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

    const updated = await postModel.updatePost(req.params.id, {
      content:      content?.trim()      || null,
      privacy:      privacy              || null,
      imageUrl:     image_url            || null,
      imageUrls,
      linkUrl:      link_url             || null,
      articleTitle: article_title        || null,
    });

    if (!updated) {
      const err = new Error('Post not found or already deleted');
      err.status = 404;
      return next(err);
    }

    // Nội dung đổi → re-embed chunk với text mới (tags giữ nguyên)
    enqueuePostEmbed(req.params.id)
      .catch((err) => logger.warn({ err, postId: req.params.id }, 'updatePost: enqueue embed failed'));

    res.json({ data: updated });
  } catch (err) {
    next(err);
  }
}

module.exports = { listPosts, getPost, analyzePost, createPost, sharePost, softDeletePost, updatePost };
