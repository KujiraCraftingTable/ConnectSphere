-- ─────────────────────────────────────────────────────────────────────────────
-- 096, "Hide all from this person"
--
-- After reporting a post, someone can choose to stop seeing everything from
-- its author without blocking them: each row is one author a user hid. Their
-- posts leave that user's feed, tag feed and lists, but the author's own
-- profile page and direct links still work (same rule as hidden_posts, 005).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS hidden_authors (
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  author_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, author_id),
  CHECK (user_id <> author_id)
);
