/**
 * interactionRoutes.js  (mounted under /api/posts/:id — already passed through authMiddleware)
 * POST   /api/posts/:id/like                       — toggle like post
 * GET    /api/posts/:id/comments                   — list comments (with replies, likes)
 * POST   /api/posts/:id/comments                   — add comment / reply
 * DELETE /api/posts/:id/comments/:commentId        — delete a comment (comment author or post owner)
 * PATCH  /api/posts/:id/comments/:commentId        — edit a comment's content (comment author only)
 * POST   /api/posts/:id/comments/:commentId/restore — restore a deleted comment (comment author only)
 * POST   /api/posts/:id/comments/:commentId/like   — toggle like comment
 * POST   /api/posts/:id/hide                       — hide the post from your own feed
 * DELETE /api/posts/:id/hide                       — unhide it
 * POST   /api/posts/:id/save                       — save the post
 * DELETE /api/posts/:id/save                       — unsave it
 */

const router = require('express').Router({ mergeParams: true });
const { query, withTransaction } = require('../config/db');
const postModel = require('../models/postModel');
const {
  pushUserNotification, actorPayload, hasPendingDuplicate,
} = require('../services/userNotifyService');
const { emitToRoom } = require('../utils/realtime');
const { personaExpr } = require('../utils/personaSql');
const logger = require('../utils/logger');

// Checks existence + VIEW permission (privacy/block via findById), then returns
// the author id + mode (to resolve the interacting persona). If you can't view
// it, you can't like/comment on it either. community_id is fetched separately via findPostMeta —
// buildPostSelect (findById's shared SELECT) doesn't project that column, and
// this route file is shared by Feed + Community posts so it's added here
// rather than touching the already-tested findById/buildPostSelect shape.
async function fetchVisiblePostMeta(postId, viewerId) {
  const post = await postModel.findById(postId, viewerId);
  if (!post) return null;
  const meta = await postModel.findPostMeta(postId);
  return { id: post.id, author_id: post.author.id, mode: post.mode, community_id: meta?.community_id ?? null };
}

// ── Like toggle ───────────────────────────────────────────────────────────────

router.post('/like', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    const userId = req.userId;

    const post = await fetchVisiblePostMeta(postId, userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    // The like/unlike row change and the like_count adjustment must land
    // together — a crash between them permanently desyncs the counter.
    const liked = await withTransaction(async (client) => {
      // INSERT first — ON CONFLICT tells us whether it was already liked without
      // racing between the check step and the write step.
      const inserted = await client.query(
        `INSERT INTO post_likes (post_id, user_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING
         RETURNING 1`,
        [postId, userId]
      );

      if (inserted.rows.length > 0) {
        await client.query('UPDATE posts SET like_count = like_count + 1 WHERE id = $1', [postId]);
        return true;
      }
      const del = await client.query(
        'DELETE FROM post_likes WHERE post_id = $1 AND user_id = $2', [postId, userId]
      );
      if (del.rowCount > 0) {
        await client.query('UPDATE posts SET like_count = GREATEST(like_count - 1, 0) WHERE id = $1', [postId]);
      }
      return false;
    });

    const { rows: [row] } = await query('SELECT like_count FROM posts WHERE id = $1', [postId]);
    res.json({ liked, like_count: row.like_count });

    // Live like-count update for open community viewers — gated strictly on
    // community_id so Feed posts (community_id null) never broadcast.
    if (post.community_id) {
      emitToRoom(`community:${post.community_id}`, 'community_post_liked', {
        postId, likeCount: row.like_count, isLiked: liked, userId,
      });
    }

    // Notification for the post owner — fire-and-forget, deduped so rapid
    // like/unlike toggling doesn't spam.
    if (liked && post.author_id !== userId) {
      (async () => {
        const dupe = await hasPendingDuplicate({
          userId: post.author_id, type: 'post_liked', groupTargetId: postId, actorId: userId,
        });
        if (!dupe) {
          await pushUserNotification({
            userId:  post.author_id,
            type:    'post_liked',
            postId,
            actorId: userId,
            payload: await actorPayload(userId),
          });
        }
      })().catch((err) => logger.warn({ err, postId }, 'post_liked notification failed'));
    }
  } catch (err) { next(err); }
});

// ── Comments ──────────────────────────────────────────────────────────────────

router.get('/comments', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    const limit  = Math.min(parseInt(req.query.limit  || '50', 10) || 50, 100);
    const offset = Math.max(parseInt(req.query.offset || '0',  10) || 0, 0);

    if (!(await fetchVisiblePostMeta(postId, req.userId))) {
      return res.status(404).json({ error: 'Post not found' });
    }

    const { rows } = await query(
      `SELECT c.id, c.content, c.created_at, c.parent_comment_id, c.like_count,
              EXISTS(
                SELECT 1 FROM comment_likes cl
                WHERE cl.comment_id = c.id AND cl.user_id = $4
              ) AS is_liked,
              json_build_object(
                'id',           u.id,
                'display_name', ${personaExpr('display_name', 'p.mode')},
                'avatar_color', u.avatar_color,
                'avatar_url',   ${personaExpr('avatar_url', 'p.mode')}
              ) AS author
       FROM comments c
       JOIN posts p ON p.id = c.post_id
       JOIN users u ON u.id = c.author_id
       WHERE c.post_id = $1 AND c.status = 'posted'
       ORDER BY c.created_at ASC
       LIMIT $2 OFFSET $3`,
      [postId, limit, offset, req.userId]
    );

    const { rows: [{ count }] } = await query(
      "SELECT COUNT(*) FROM comments WHERE post_id = $1 AND status = 'posted'", [postId]
    );

    res.json({ data: rows, total: parseInt(count, 10) });
  } catch (err) { next(err); }
});

router.post('/comments', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    const { content, parent_comment_id = null } = req.body;

    if (!content?.trim()) return res.status(400).json({ error: 'content is required' });

    const post = await fetchVisiblePostMeta(postId, req.userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    // Reply: the parent must be a top-level comment (1 level deep) on the same post
    let parent = null;
    if (parent_comment_id) {
      const { rows } = await query(
        `SELECT id, author_id, parent_comment_id FROM comments
         WHERE id = $1 AND post_id = $2 AND status = 'posted'`,
        [parent_comment_id, postId]
      );
      parent = rows[0];
      if (!parent) return res.status(404).json({ error: 'Parent comment not found' });
      if (parent.parent_comment_id) {
        return res.status(400).json({ error: 'Replies can only be one level deep' });
      }
    }

    const { comment, commentCount } = await withTransaction(async (client) => {
      const { rows: [c] } = await client.query(
        `INSERT INTO comments (post_id, author_id, content, parent_comment_id)
         VALUES ($1, $2, $3, $4)
         RETURNING id, content, created_at, parent_comment_id, like_count`,
        [postId, req.userId, content.trim(), parent_comment_id]
      );
      const { rows: [{ comment_count: cc }] } = await client.query(
        'UPDATE posts SET comment_count = comment_count + 1 WHERE id = $1 RETURNING comment_count',
        [postId]
      );
      return { comment: c, commentCount: cc };
    });

    // Commenter's identity resolved for the post's mode (post.mode from fetchVisiblePostMeta)
    const { rows: [author] } = await query(
      `SELECT id,
              ${personaExpr('display_name', '$2', 'users')} AS display_name,
              avatar_color,
              ${personaExpr('avatar_url', '$2', 'users')} AS avatar_url
       FROM users WHERE id = $1`,
      [req.userId, post.mode]
    );

    const commentPayload = { ...comment, is_liked: false, author };
    res.status(201).json({ data: commentPayload });

    // Live comment update for open community viewers — same gating as the
    // like handler above.
    if (post.community_id) {
      emitToRoom(`community:${post.community_id}`, 'community_post_commented', {
        postId, commentCount, comment: commentPayload,
      });
    }

    // Notifications — fire-and-forget
    (async () => {
      const excerpt = content.trim().slice(0, 120);
      const actor   = await actorPayload(req.userId);

      // Post owner (unless commenting on your own post). entityId is the
      // comment so a tap can scroll to it, but the row groups by the post so
      // several comments collapse into one "and 2 others" line.
      if (post.author_id !== req.userId) {
        await pushUserNotification({
          userId:        post.author_id,
          type:          'post_commented',
          postId,
          actorId:       req.userId,
          entityId:      comment.id,
          groupTargetId: postId,
          payload:       { ...actor, excerpt, commentId: comment.id },
        });
      }
      // Original comment's author when replied to (unless replying to your own comment / already notified as post owner)
      if (parent && parent.author_id !== req.userId && parent.author_id !== post.author_id) {
        await pushUserNotification({
          userId:        parent.author_id,
          type:          'comment_replied',
          postId,
          actorId:       req.userId,
          entityId:      comment.id,
          groupTargetId: parent.id,
          payload:       { ...actor, excerpt, commentId: comment.id, parentCommentId: parent.id },
        });
      }
    })().catch((err) => logger.warn({ err, postId }, 'comment notification failed'));
  } catch (err) { next(err); }
});

// Delete a comment — comment author or post owner; also soft-deletes its replies
router.delete('/comments/:commentId', async (req, res, next) => {
  try {
    const { id: postId, commentId } = req.params;

    const post = await fetchVisiblePostMeta(postId, req.userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    const { rows: [comment] } = await query(
      `SELECT id, author_id FROM comments
       WHERE id = $1 AND post_id = $2 AND status = 'posted'`,
      [commentId, postId]
    );
    if (!comment) return res.status(404).json({ error: 'Comment not found' });

    if (comment.author_id !== req.userId && post.author_id !== req.userId) {
      return res.status(403).json({ error: 'Not allowed to delete this comment' });
    }

    const rowCount = await withTransaction(async (client) => {
      const del = await client.query(
        `UPDATE comments SET status = 'deleted', deleted_at = NOW()
         WHERE (id = $1 OR parent_comment_id = $1) AND status = 'posted'`,
        [commentId]
      );
      await client.query(
        'UPDATE posts SET comment_count = GREATEST(comment_count - $2, 0) WHERE id = $1',
        [postId, del.rowCount]
      );
      return del.rowCount;
    });

    res.json({ status: 'ok', removed: rowCount });
  } catch (err) { next(err); }
});

// Edit a comment's content — ONLY the comment's own author (unlike deletion,
// which allows either the comment author or the post owner) — editing someone
// else's words is a very different (and much stranger) permission than taking
// it down, so we don't reuse the delete rule above. 404s if the comment
// doesn't exist, doesn't belong to this post, or is soft-deleted
// (status != 'posted') — you can't edit something that's sitting in the
// trash. The response returns the exact shape that POST /comments returns, so
// iOS can decode it as the same existing CommentDTO.
router.patch('/comments/:commentId', async (req, res, next) => {
  try {
    const { id: postId, commentId } = req.params;
    const { content } = req.body;

    if (!content?.trim()) return res.status(400).json({ error: 'content is required' });

    const post = await fetchVisiblePostMeta(postId, req.userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    const { rows: [comment] } = await query(
      `SELECT id, author_id FROM comments
       WHERE id = $1 AND post_id = $2 AND status = 'posted'`,
      [commentId, postId]
    );
    if (!comment) return res.status(404).json({ error: 'Comment not found' });

    if (comment.author_id !== req.userId) {
      return res.status(403).json({ error: 'Not allowed to edit this comment' });
    }

    const { rows: [updated] } = await query(
      `UPDATE comments SET content = $1
       WHERE id = $2
       RETURNING id, content, created_at, parent_comment_id, like_count`,
      [content.trim(), commentId]
    );

    const { rows: [{ is_liked: isLiked }] } = await query(
      `SELECT EXISTS(
         SELECT 1 FROM comment_likes WHERE comment_id = $1 AND user_id = $2
       ) AS is_liked`,
      [commentId, req.userId]
    );

    const { rows: [author] } = await query(
      `SELECT id,
              ${personaExpr('display_name', '$2', 'users')} AS display_name,
              avatar_color,
              ${personaExpr('avatar_url', '$2', 'users')} AS avatar_url
       FROM users WHERE id = $1`,
      [req.userId, post.mode]
    );

    res.json({ data: { ...updated, is_liked: isLiked, author } });
  } catch (err) { next(err); }
});

// Restore a soft-deleted comment — only the COMMENT'S author (unlike deletion,
// which allows either the comment author or the post owner) — mirrors postService.restorePost's
// own author-only rule for posts, kept simple per plan. Does not automatically
// restore replies that were soft-deleted alongside the parent comment (each
// comment/reply has its own author, and only that specific author can restore
// it). Re-increments comment_count on the post — the exact inverse of the
// decrement done on delete above.
router.post('/comments/:commentId/restore', async (req, res, next) => {
  try {
    const { id: postId, commentId } = req.params;

    const post = await fetchVisiblePostMeta(postId, req.userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    const { rows: [comment] } = await query(
      `SELECT id, author_id FROM comments
       WHERE id = $1 AND post_id = $2 AND status = 'deleted'`,
      [commentId, postId]
    );
    if (!comment) return res.status(404).json({ error: 'Comment not found or not deleted' });

    if (comment.author_id !== req.userId) {
      return res.status(403).json({ error: 'Not allowed to restore this comment' });
    }

    // Atomic + status-guarded so a double-tap / retry can't restore twice and
    // inflate comment_count (mirrors the delete handler above).
    const { restored, commentCount } = await withTransaction(async (client) => {
      const { rows: [r] } = await client.query(
        `UPDATE comments SET status = 'posted', deleted_at = NULL
         WHERE id = $1 AND status = 'deleted'
         RETURNING id, content, created_at, parent_comment_id, like_count`,
        [commentId]
      );
      if (!r) return { restored: null, commentCount: null };
      const { rows: [{ comment_count: cc }] } = await client.query(
        'UPDATE posts SET comment_count = comment_count + 1 WHERE id = $1 RETURNING comment_count',
        [postId]
      );
      return { restored: r, commentCount: cc };
    });
    if (!restored) return res.status(409).json({ error: 'Comment is not currently deleted' });

    const { rows: [author] } = await query(
      `SELECT id,
              ${personaExpr('display_name', '$2', 'users')} AS display_name,
              avatar_color,
              ${personaExpr('avatar_url', '$2', 'users')} AS avatar_url
       FROM users WHERE id = $1`,
      [req.userId, post.mode]
    );

    res.json({ data: { ...restored, is_liked: false, author }, comment_count: commentCount });
  } catch (err) { next(err); }
});

// ── Hide / Unhide (hide the post from your own feed) ───────────────────────────

router.post('/hide', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    if (!(await fetchVisiblePostMeta(postId, req.userId))) {
      return res.status(404).json({ error: 'Post not found' });
    }
    await query(
      `INSERT INTO hidden_posts (user_id, post_id) VALUES ($1, $2)
       ON CONFLICT DO NOTHING`,
      [req.userId, postId]
    );
    res.json({ status: 'ok', hidden: true });
  } catch (err) { next(err); }
});

router.delete('/hide', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    await query(
      'DELETE FROM hidden_posts WHERE user_id = $1 AND post_id = $2',
      [req.userId, postId]
    );
    res.json({ status: 'ok', hidden: false });
  } catch (err) { next(err); }
});

// ── Save / Unsave (save the post to look at again later) ───────────────────────────────

router.post('/save', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    if (!(await fetchVisiblePostMeta(postId, req.userId))) {
      return res.status(404).json({ error: 'Post not found' });
    }
    await query(
      `INSERT INTO saved_posts (user_id, post_id) VALUES ($1, $2)
       ON CONFLICT DO NOTHING`,
      [req.userId, postId]
    );
    res.json({ status: 'ok', saved: true });
  } catch (err) { next(err); }
});

router.delete('/save', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    await query(
      'DELETE FROM saved_posts WHERE user_id = $1 AND post_id = $2',
      [req.userId, postId]
    );
    res.json({ status: 'ok', saved: false });
  } catch (err) { next(err); }
});

// Toggle like on a comment
router.post('/comments/:commentId/like', async (req, res, next) => {
  try {
    const { id: postId, commentId } = req.params;
    const userId = req.userId;

    if (!(await fetchVisiblePostMeta(postId, userId))) {
      return res.status(404).json({ error: 'Post not found' });
    }

    const { rows: [comment] } = await query(
      `SELECT id, author_id, content FROM comments
       WHERE id = $1 AND post_id = $2 AND status = 'posted'`,
      [commentId, postId]
    );
    if (!comment) return res.status(404).json({ error: 'Comment not found' });

    const inserted = await query(
      `INSERT INTO comment_likes (comment_id, user_id) VALUES ($1, $2)
       ON CONFLICT DO NOTHING
       RETURNING 1`,
      [commentId, userId]
    );

    let liked;
    if (inserted.rows.length > 0) {
      await query('UPDATE comments SET like_count = like_count + 1 WHERE id = $1', [commentId]);
      liked = true;
    } else {
      const del = await query(
        'DELETE FROM comment_likes WHERE comment_id = $1 AND user_id = $2', [commentId, userId]
      );
      if (del.rowCount > 0) {
        await query('UPDATE comments SET like_count = GREATEST(like_count - 1, 0) WHERE id = $1', [commentId]);
      }
      liked = false;
    }

    const { rows: [row] } = await query('SELECT like_count FROM comments WHERE id = $1', [commentId]);
    res.json({ liked, like_count: row.like_count });

    // Notify the comment's author — fire-and-forget, deduped the same way the
    // post-like handler is so toggling doesn't spam.
    if (liked && comment.author_id !== userId) {
      (async () => {
        const dupe = await hasPendingDuplicate({
          userId: comment.author_id, type: 'comment_liked',
          groupTargetId: commentId, actorId: userId,
        });
        if (!dupe) {
          await pushUserNotification({
            userId:        comment.author_id,
            type:          'comment_liked',
            postId,
            actorId:       userId,
            entityId:      commentId,
            groupTargetId: commentId,
            payload: {
              ...(await actorPayload(userId)),
              commentId,
              commentExcerpt: (comment.content ?? '').slice(0, 120) || null,
            },
          });
        }
      })().catch((err) => logger.warn({ err, commentId }, 'comment_liked notification failed'));
    }
  } catch (err) { next(err); }
});

module.exports = router;
