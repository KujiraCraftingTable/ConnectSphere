-- Migration 009: communities feature

-- ── communities ───────────────────────────────────────────────────────────────

CREATE TABLE communities (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name         VARCHAR(100) NOT NULL,
  description  TEXT,
  type         VARCHAR(10)  NOT NULL CHECK (type IN ('fandom', 'work')),
  privacy      VARCHAR(10)  NOT NULL DEFAULT 'public'
               CHECK (privacy IN ('public', 'private')),
  icon_emoji   VARCHAR(10)  NOT NULL DEFAULT '👥',
  cover_color  VARCHAR(7)   NOT NULL DEFAULT '#7F5AF0',
  member_count INTEGER      NOT NULL DEFAULT 0,
  post_count   INTEGER      NOT NULL DEFAULT 0,
  created_by   UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Case-insensitive unique name
CREATE UNIQUE INDEX idx_communities_name_lower ON communities (LOWER(name));
CREATE INDEX        idx_communities_type       ON communities (type);

CREATE TRIGGER trg_communities_updated_at
  BEFORE UPDATE ON communities
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── community_members ─────────────────────────────────────────────────────────

CREATE TABLE community_members (
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
  role         VARCHAR(10) NOT NULL DEFAULT 'member'
               CHECK (role IN ('admin', 'moderator', 'member')),
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (community_id, user_id)
);

CREATE INDEX idx_community_members_user ON community_members (user_id);

-- ── Extend posts with community_id ────────────────────────────────────────────

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS community_id UUID REFERENCES communities(id) ON DELETE SET NULL;

CREATE INDEX idx_posts_community_id ON posts (community_id, created_at DESC);
