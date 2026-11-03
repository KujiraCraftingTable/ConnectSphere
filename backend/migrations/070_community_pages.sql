-- ─────────────────────────────────────────────────────────────────────────────
-- 070 — Community pages (Facebook-group style)
--
-- Communities get a cover photo (no profile picture any more), optional
-- post approval and a record of the last rename. Each member gets a
-- notification level and can pin the community. Posts carry their review
-- (pending → posted | declined) and can share a community to the feed.
-- A whole community can be reported (reviewed by the app owner).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE communities
  ADD COLUMN IF NOT EXISTS cover_url             TEXT,
  ADD COLUMN IF NOT EXISTS require_post_approval BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS name_changed_at       TIMESTAMPTZ;

ALTER TABLE community_members
  ADD COLUMN IF NOT EXISTS notify_level VARCHAR(8) NOT NULL DEFAULT 'friends'
    CHECK (notify_level IN ('all', 'friends', 'off')),
  ADD COLUMN IF NOT EXISTS pinned_at    TIMESTAMPTZ;

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS decline_reason      TEXT,
  ADD COLUMN IF NOT EXISTS reviewed_by         UUID REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reviewed_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS shared_community_id UUID REFERENCES communities(id) ON DELETE SET NULL;

-- A community's own review queue.
CREATE INDEX IF NOT EXISTS idx_posts_community_pending
  ON posts (community_id, created_at) WHERE status = 'pending';

ALTER TABLE community_reports DROP CONSTRAINT IF EXISTS community_reports_target_type_check;
ALTER TABLE community_reports ADD CONSTRAINT community_reports_target_type_check
  CHECK (target_type IN ('post', 'member', 'community'));
