-- 019_post_state.sql
-- Add the post_state ENUM type and a state column to posts.
-- 'posted'  = post is shown normally
-- 'deleted' = soft delete, hidden from the feed (the row is kept)

CREATE TYPE post_state AS ENUM ('posted', 'deleted');

ALTER TABLE posts
  ADD COLUMN state post_state NOT NULL DEFAULT 'posted';

-- Migrate all existing posts to 'posted'
UPDATE posts SET state = 'posted';

-- Index to quickly filter out posts that are not deleted
CREATE INDEX idx_posts_state ON posts (state);
