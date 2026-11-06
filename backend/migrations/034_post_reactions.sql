-- Every reaction a user has made to a post, in one place: AI people search
-- treats reacting to a post about X as evidence of interest in X.
--
-- A view rather than a table: the source rows already exist (post_likes,
-- comments, shares as posts.shared_post_id), so a copy could only drift.
-- Indexed by post_likes_pkey, idx_comments_post and idx_posts_shared.
--
-- `is_public` says whether others can already see the reaction: likes never
-- (only counts are shown), comments yes (on the public posts search uses),
-- shares only when the repost itself is public. Search may rank by any
-- reaction but must only ever *display* public ones. See SearchStore.vectorSearch.
CREATE OR REPLACE VIEW post_reactions AS
  SELECT user_id, post_id, 'like'::text AS kind, FALSE AS is_public, created_at FROM post_likes
  UNION ALL
  SELECT author_id, post_id, 'comment', TRUE, created_at FROM comments WHERE status = 'posted'
  UNION ALL
  SELECT author_id, shared_post_id, 'share', privacy = 'public', created_at FROM posts
  WHERE shared_post_id IS NOT NULL AND status = 'posted';
