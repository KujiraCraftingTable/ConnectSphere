-- 005_hidden_posts.sql
-- "Hide post": each row = one post that a user has hidden from their feed.
-- A hidden post is excluded from all of that user's own listings (suggested
-- feed, post lists, tag feed), but can still be opened directly via PostDetail
-- (share embed, notification) so referenced links never break.

CREATE TABLE hidden_posts (
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, post_id)
);
