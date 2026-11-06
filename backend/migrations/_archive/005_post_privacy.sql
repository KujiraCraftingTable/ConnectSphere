-- Migration 005: add privacy to posts

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS privacy VARCHAR(20) NOT NULL DEFAULT 'public'
  CHECK (privacy IN ('public', 'friends', 'specific', 'only_me'));

CREATE INDEX IF NOT EXISTS idx_posts_privacy ON posts (privacy);
