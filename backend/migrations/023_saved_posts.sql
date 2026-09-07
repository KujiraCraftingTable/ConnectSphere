-- 023_saved_posts.sql
-- "Save post": each row = one post a user has saved (bookmarked) to view again later.
-- Mirrors 005_hidden_posts.sql's exact shape.

CREATE TABLE saved_posts (
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, post_id)
);
