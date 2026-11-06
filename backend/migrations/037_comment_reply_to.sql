-- ─────────────────────────────────────────────────────────────────────────────
-- 037, Which comment a reply answers
--
-- Threads stop at three levels (comment → reply → reply-to-reply). Replying to
-- a third-level reply keeps the new comment at that level, it's placed under
-- the same parent, so `parent_comment_id` alone no longer says who is being
-- answered. `reply_to_comment_id` records it, for the "A replied to B" line and
-- for notifying the right person. NULL on top-level comments and on replies
-- written before this column existed (those answer their parent).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE comments
  ADD COLUMN reply_to_comment_id UUID REFERENCES comments(id) ON DELETE SET NULL;
