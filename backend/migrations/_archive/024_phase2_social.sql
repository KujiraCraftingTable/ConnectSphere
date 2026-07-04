-- Migration 024: Phase 2 social features
-- 1. Avatar ảnh thật cho user (trước đây chỉ có avatar_color)
-- 2. Comment nâng cao: reply (parent_comment_id) + like (comment_likes, like_count)
-- 3. Block user (user_blocks)

-- ── 1. Avatar URL ─────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- ── 2. Comment replies + likes ───────────────────────────────────────────────

ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS parent_comment_id UUID REFERENCES comments (id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS like_count INT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments (parent_comment_id);

CREATE TABLE IF NOT EXISTS comment_likes (
  comment_id UUID        NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users (id)    ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (comment_id, user_id)
);

-- ── 3. User blocks ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  blocked_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks (blocked_id);
