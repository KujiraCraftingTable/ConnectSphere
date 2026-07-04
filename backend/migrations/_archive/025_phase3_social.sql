-- Migration 025: Phase 3 social features
-- 1. Stories 24h (stories + story_views)
-- 2. Thu hồi tin nhắn (messages.deleted_at)
-- 3. Repost/share (posts.shared_post_id)

-- ── 1. Stories ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS stories (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  image_url  TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX IF NOT EXISTS idx_stories_author  ON stories (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stories_expires ON stories (expires_at);

CREATE TABLE IF NOT EXISTS story_views (
  story_id  UUID        NOT NULL REFERENCES stories (id) ON DELETE CASCADE,
  viewer_id UUID        NOT NULL REFERENCES users (id)   ON DELETE CASCADE,
  viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (story_id, viewer_id)
);

-- ── 2. Thu hồi tin nhắn ───────────────────────────────────────────────────────

ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- ── 3. Repost / share ─────────────────────────────────────────────────────────
-- ON DELETE SET NULL: bài gốc bị xóa cứng thì bài share hiện "nội dung không còn"

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS shared_post_id UUID REFERENCES posts (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_posts_shared ON posts (shared_post_id);
