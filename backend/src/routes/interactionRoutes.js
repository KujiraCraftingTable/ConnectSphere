/**
 * interactionRoutes.js  (mounted dưới /api/posts/:id — đã qua authMiddleware)
 * POST   /api/posts/:id/like                       — toggle like post
 * GET    /api/posts/:id/comments                   — list comments (kèm reply, like)
 * POST   /api/posts/:id/comments                   — add comment / reply
 * DELETE /api/posts/:id/comments/:commentId        — xóa comment (tác giả comment hoặc chủ post)
 * POST   /api/posts/:id/comments/:commentId/like   — toggle like comment
 * POST   /api/posts/:id/hide                       — ẩn bài khỏi feed của mình
 * DELETE /api/posts/:id/hide                       — bỏ ẩn
 */

const router = require('express').Router({ mergeParams: true });
const { query } = require('../config/db');
const postModel = require('../models/postModel');
const {
  pushUserNotification, actorPayload, hasRecentDuplicate,
} = require('../services/userNotifyService');
const { personaExpr } = require('../utils/personaSql');
const logger = require('../utils/logger');

// Check tồn tại + quyền XEM (privacy/block qua findById) rồi trả về author id
// + mode (để resolve persona người tương tác). Không xem được thì cũng không
// like/comment được.
async function fetchVisiblePostMeta(postId, viewerId) {
  const post = await postModel.findById(postId, viewerId);
  if (!post) return null;
  return { id: post.id, author_id: post.author.id, mode: post.mode };
}

// ── Like toggle ───────────────────────────────────────────────────────────────

router.post('/like', async (req, res, next) => {
  try {
    const { id: postId } = req.params;
    const userId = req.userId;

    const post = await fetchVisiblePostMeta(postId, userId);
    if (!post) return res.status(404).json({ error: 'Post not found' });

    // INSERT trước — ON CONFLICT cho biết đã like hay chưa mà không bị race
    // giữa bước check và bước ghi.
    const inserted = await query(
      `INSERT INTO post_likes (post_id, user_id) VALUES ($1, $2)
       ON CONFLICT DO NOTHING
       RETURNING 1`,
      [postId, userId]
    );

    let liked;
    if (inserted.rows.length > 0) {
      await query('UPDATE posts SET like_count = like_count + 1 WHERE id = $1', [postId]);
      liked = true;
    } else {
      const del = await query(
        'DELETE FROM post_likes WHERE post_id = $1 AND user_id = $2', [postId, userId]
      );
      if (del.rowCount > 0) {
        await query('UPDATE posts SET like_count = GREATEST(like_count - 1, 0) WHERE id = $1', [postId]);
      }
      liked = false;
    }

    const { rows: [row] } = await query('SELECT like_count FROM posts WHERE id = $1', [postId]);
    res.json({ liked, like_count: row.like_count });

    // Notification cho chủ post — fire-and-forget, dedupe để like/unlike
    // liên tục không spam.
    if (liked && post.author_id !== userId) {
      (async () => {
        const dupe = await hasRecentDuplicate({
          userId: post.author_id, type: 'post_liked', postId, fromUserId: userId,
        });
        if (!dupe) {
          await pushUserNotification({
            userId:  post.author_id,
            type:    'post_liked',
            postId,
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

    // Reply: parent phải là comment gốc (1 tầng) thuộc cùng post
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

    const { rows: [comment] } = await query(
      `INSERT INTO comments (post_id, author_id, content, parent_comment_id)
       VALUES ($1, $2, $3, $4)
       RETURNING id, content, created_at, parent_comment_id, like_count`,
      [postId, req.userId, content.trim(), parent_comment_id]
    );

    await query('UPDATE posts SET comment_count = comment_count + 1 WHERE id = $1', [postId]);

    // Danh tính người comment theo mode của bài (post.mode từ fetchVisiblePostMeta)
    const { rows: [author] } = await query(
      `SELECT id,
              ${personaExpr('display_name', '$2', 'users')} AS display_name,
              avatar_color,
              ${personaExpr('avatar_url', '$2', 'users')} AS avatar_url
       FROM users WHERE id = $1`,
      [req.userId, post.mode]
    );

    res.status(201).json({ data: { ...comment, is_liked: false, author } });

    // Notifications — fire-and-forget
    (async () => {
      const excerpt = content.trim().slice(0, 120);
      const actor   = await actorPayload(req.userId);

      // Chủ post (trừ khi tự comment bài mình)
      if (post.author_id !== req.userId) {
        await pushUserNotification({
          userId:  post.author_id,
          type:    'post_commented',
          postId,
          payload: { ...actor, excerpt },
        });
      }
      // Tác giả comment gốc khi bị reply (trừ tự reply mình / trùng chủ post đã báo)
      if (parent && parent.author_id !== req.userId && parent.author_id !== post.author_id) {
        await pushUserNotification({
          userId:  parent.author_id,
          type:    'comment_replied',
          postId,
          payload: { ...actor, excerpt },
        });
      }
    })().catch((err) => logger.warn({ err, postId }, 'comment notification failed'));
  } catch (err) { next(err); }
});

// Xóa comment — tác giả comment hoặc chủ post; xóa mềm cả replies của nó
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

    const { rowCount } = await query(
      `UPDATE comments SET status = 'deleted'
       WHERE (id = $1 OR parent_comment_id = $1) AND status = 'posted'`,
      [commentId]
    );
    await query(
      'UPDATE posts SET comment_count = GREATEST(comment_count - $2, 0) WHERE id = $1',
      [postId, rowCount]
    );

    res.json({ status: 'ok', removed: rowCount });
  } catch (err) { next(err); }
});

// ── Hide / Unhide (ẩn bài khỏi feed của riêng mình) ───────────────────────────

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

// Toggle like một comment
router.post('/comments/:commentId/like', async (req, res, next) => {
  try {
    const { id: postId, commentId } = req.params;
    const userId = req.userId;

    const { rows: [comment] } = await query(
      `SELECT id FROM comments WHERE id = $1 AND post_id = $2 AND status = 'posted'`,
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
  } catch (err) { next(err); }
});

module.exports = router;
