-- ─────────────────────────────────────────────────────────────────────────────
-- 077 — "Not interested" / "Show more like this" (feed ranking, phase C)
--
-- One row per viewer × post. For 30 days the For you feed pushes down
-- ('less') or lifts ('more') posts similar to it and posts by its author, and
-- the viewer's taste counts it against / towards that kind of post. A 'less'
-- post itself leaves their feed. `author_id` is copied so the author rule
-- needs no join, and still works if the post is later deleted.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS post_feedback (
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  author_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind       TEXT        NOT NULL CHECK (kind IN ('less', 'more')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX IF NOT EXISTS post_feedback_user_idx ON post_feedback (user_id, created_at DESC);
