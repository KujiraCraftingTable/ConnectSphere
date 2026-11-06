-- 020_rename_state_to_status.sql
-- 1. Add the 'banned' value to the post_state ENUM
-- 2. Rename the ENUM post_state → post_status
-- 3. Rename the column state → status on posts
-- 4. Add a status column to comments

ALTER TYPE post_state ADD VALUE IF NOT EXISTS 'banned';
ALTER TYPE post_state RENAME TO post_status;

ALTER TABLE posts RENAME COLUMN state TO status;

ALTER TABLE comments
  ADD COLUMN status post_status NOT NULL DEFAULT 'posted';

CREATE INDEX idx_comments_status ON comments (status);
