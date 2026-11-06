-- ═══════════════════════════════════════════════════════════════════════════
-- 001_init.sql, ConnectSphere clean baseline schema
--
-- Consolidates former migrations 001–026 into one file, with the schema
-- restructure approved on 2026-07-04:
--   • user_embedding_chunks replaces users.embedding / posts.embedding
--     (chunk-based retrieval: user_profile + post chunks, metadata per chunk)
--   • dead columns removed  : user_interests.{category,entity_id,raw_input}
--   • posts.image_url merged into posts.image_urls TEXT[]
--   • posts.privacy 'specific' removed (no audience table; was author-only)
--   • connections status 'blocked' removed (blocking lives in user_blocks)
--   • users.password_hash nullable (Google Sign-In accounts have no password)
--
-- Seed data lives in separate files run after this one:
--   002_seed_work_entities.sql (interest_entities rows, pre-computed embeddings)
--   003_seed_vn_wards.sql      (Vietnamese administrative units)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS vector;

-- Shared trigger: keep updated_at fresh on every UPDATE
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Soft-delete / moderation state shared by posts and comments
CREATE TYPE post_status AS ENUM ('posted', 'deleted', 'banned');

-- ─── vn_wards, Vietnamese administrative units (data in 003 seed) ───────────

CREATE TABLE vn_wards (
  id               UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  code             VARCHAR(10)      NOT NULL UNIQUE,
  name             TEXT             NOT NULL,
  name_en          TEXT             NOT NULL,
  full_name        TEXT             NOT NULL,
  full_name_en     TEXT             NOT NULL,
  province_code    VARCHAR(5)       NOT NULL,
  province_name    TEXT             NOT NULL,
  province_name_en TEXT             NOT NULL,
  unit_type        VARCHAR(30)      NOT NULL,
  lat              DOUBLE PRECISION NOT NULL,
  lng              DOUBLE PRECISION NOT NULL
);

CREATE INDEX idx_vn_wards_province ON vn_wards (province_code);
CREATE INDEX idx_vn_wards_code     ON vn_wards (code);

-- ─── users ────────────────────────────────────────────────────────────────────

CREATE TABLE users (
  id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  username         VARCHAR(50)  UNIQUE NOT NULL,
  password_hash    VARCHAR(255),              -- NULL for Google Sign-In accounts
  display_name     VARCHAR(100) NOT NULL,
  bio              TEXT,
  avatar_color     VARCHAR(7)   NOT NULL DEFAULT '#1877F2',
  avatar_url       TEXT,
  location         VARCHAR(100),
  ward_id          UUID         REFERENCES vn_wards(id) ON DELETE SET NULL,
  gender           VARCHAR(10)  NOT NULL DEFAULT 'other'
                   CHECK (gender IN ('male', 'female', 'other')),
  dob              DATE,

  -- Colleague-mode fields
  job_title        VARCHAR(100),
  company          VARCHAR(100),

  -- Contact & auth
  phone            VARCHAR(20),
  email            VARCHAR(255) UNIQUE,
  google_id        TEXT         UNIQUE,
  is_setup         BOOLEAN      NOT NULL DEFAULT FALSE,  -- FALSE = needs onboarding

  -- Mode & theme preferences
  default_mode     VARCHAR(20)  NOT NULL DEFAULT 'friend'
                   CHECK (default_mode IN ('friend', 'colleague')),
  friend_theme     VARCHAR(20)  NOT NULL DEFAULT 'blue',
  colleague_theme  VARCHAR(20)  NOT NULL DEFAULT 'blue',

  -- Denormalised counters (updated via application logic)
  follower_count   INT NOT NULL DEFAULT 0,
  following_count  INT NOT NULL DEFAULT 0,
  post_count       INT NOT NULL DEFAULT 0,

  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_username ON users (username);
CREATE INDEX idx_users_email    ON users (email);
CREATE INDEX idx_users_google   ON users (google_id);
CREATE INDEX idx_users_gender   ON users (gender);
CREATE INDEX idx_users_ward_id  ON users (ward_id);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── user_skills (colleague mode) ─────────────────────────────────────────────

CREATE TABLE user_skills (
  id         SERIAL       PRIMARY KEY,
  user_id    UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  skill      VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, skill)
);

CREATE INDEX idx_user_skills_user ON user_skills (user_id);

-- ─── user_interests (friend mode) ─────────────────────────────────────────────

CREATE TABLE user_interests (
  id         SERIAL       PRIMARY KEY,
  user_id    UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  interest   VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, interest)
);

CREATE INDEX idx_user_interests_user ON user_interests (user_id);

-- ─── interest_entities, canonical entity registry (entity lookup) ────────────

CREATE TABLE interest_entities (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name TEXT         NOT NULL,
  category       VARCHAR(50)  NOT NULL,
  aliases        TEXT[]       NOT NULL DEFAULT '{}',
  wikidata_id    VARCHAR(20),                 -- e.g. "Q11214" for Naruto
  embedding      VECTOR(1024),                -- mxbai-embed-large output
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  UNIQUE (canonical_name, category)
);

CREATE INDEX idx_entities_category  ON interest_entities (category);
CREATE INDEX idx_entities_canonical ON interest_entities (canonical_name);
CREATE INDEX idx_entities_embedding ON interest_entities
  USING hnsw (embedding vector_cosine_ops);

-- ─── connections (friend / colleague requests) ────────────────────────────────

CREATE TABLE connections (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  addressee_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode         VARCHAR(20) NOT NULL CHECK (mode IN ('friend', 'colleague')),
  status       VARCHAR(20) NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'accepted', 'rejected')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One pending/accepted pair per mode; a user cannot send duplicate requests
  UNIQUE (requester_id, addressee_id, mode),
  CHECK (requester_id <> addressee_id)
);

CREATE INDEX idx_connections_requester ON connections (requester_id);
CREATE INDEX idx_connections_addressee ON connections (addressee_id);
CREATE INDEX idx_connections_status    ON connections (status);

CREATE TRIGGER trg_connections_updated_at
  BEFORE UPDATE ON connections
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── communities ──────────────────────────────────────────────────────────────

CREATE TABLE communities (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
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

CREATE UNIQUE INDEX idx_communities_name_lower ON communities (LOWER(name));
CREATE INDEX        idx_communities_type       ON communities (type);

CREATE TRIGGER trg_communities_updated_at
  BEFORE UPDATE ON communities
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE community_members (
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
  role         VARCHAR(10) NOT NULL DEFAULT 'member'
               CHECK (role IN ('admin', 'moderator', 'member')),
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (community_id, user_id)
);

CREATE INDEX idx_community_members_user ON community_members (user_id);

-- ─── posts ────────────────────────────────────────────────────────────────────

CREATE TABLE posts (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id      UUID          NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  community_id   UUID          REFERENCES communities(id) ON DELETE SET NULL,
  content        TEXT          NOT NULL,

  -- Determines layout & feed filtering on the client
  mode           VARCHAR(20)   NOT NULL CHECK (mode IN ('friend', 'colleague')),
  post_type      VARCHAR(10)   NOT NULL DEFAULT 'text'
                 CHECK (post_type IN ('text', 'poll', 'event')),
  privacy        VARCHAR(20)   NOT NULL DEFAULT 'public'
                 CHECK (privacy IN ('public', 'friends', 'only_me')),
  status         post_status   NOT NULL DEFAULT 'posted',

  image_urls     TEXT[],                       -- ordered; first item = cover image
  article_title  VARCHAR(255),
  link_url       VARCHAR(2000),

  -- Repost: original hard-deleted → shared post shows "content unavailable"
  shared_post_id UUID          REFERENCES posts (id) ON DELETE SET NULL,

  -- Community pinning
  is_pinned      BOOLEAN       NOT NULL DEFAULT FALSE,
  pinned_at      TIMESTAMPTZ,
  pinned_by      UUID          REFERENCES users(id) ON DELETE SET NULL,

  -- Denormalised counters
  like_count     INT NOT NULL DEFAULT 0,
  comment_count  INT NOT NULL DEFAULT 0,
  share_count    INT NOT NULL DEFAULT 0,

  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_posts_author       ON posts (author_id);
CREATE INDEX idx_posts_mode         ON posts (mode);
CREATE INDEX idx_posts_created      ON posts (created_at DESC);
CREATE INDEX idx_posts_privacy      ON posts (privacy);
CREATE INDEX idx_posts_status       ON posts (status);
CREATE INDEX idx_posts_community_id ON posts (community_id, created_at DESC);
CREATE INDEX idx_posts_shared       ON posts (shared_post_id);

CREATE TRIGGER trg_posts_updated_at
  BEFORE UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── post_tags / post_likes ───────────────────────────────────────────────────

CREATE TABLE post_tags (
  id      SERIAL       PRIMARY KEY,
  post_id UUID         NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  tag     VARCHAR(100) NOT NULL,
  UNIQUE (post_id, tag)
);

CREATE INDEX idx_post_tags_post ON post_tags (post_id);
CREATE INDEX idx_post_tags_tag  ON post_tags (tag);

CREATE TABLE post_likes (
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (post_id, user_id)
);

-- ─── comments ─────────────────────────────────────────────────────────────────

CREATE TABLE comments (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id           UUID        NOT NULL REFERENCES posts (id)    ON DELETE CASCADE,
  author_id         UUID        NOT NULL REFERENCES users (id)    ON DELETE CASCADE,
  parent_comment_id UUID        REFERENCES comments (id)          ON DELETE CASCADE,
  content           TEXT        NOT NULL CHECK (char_length(content) <= 1000),
  status            post_status NOT NULL DEFAULT 'posted',
  like_count        INT         NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_comments_post   ON comments (post_id, created_at DESC);
CREATE INDEX idx_comments_parent ON comments (parent_comment_id);
CREATE INDEX idx_comments_status ON comments (status);

CREATE TABLE comment_likes (
  comment_id UUID        NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users (id)    ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (comment_id, user_id)
);

-- ─── Polls (community posts with post_type = 'poll') ─────────────────────────

CREATE TABLE poll_options (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  text       VARCHAR(200) NOT NULL,
  vote_count INTEGER      NOT NULL DEFAULT 0,
  position   SMALLINT     NOT NULL,
  ends_at    TIMESTAMPTZ
);

CREATE INDEX idx_poll_options_post ON poll_options (post_id, position);

CREATE TABLE poll_votes (
  poll_option_id UUID        NOT NULL REFERENCES poll_options(id) ON DELETE CASCADE,
  user_id        UUID        NOT NULL REFERENCES users(id)        ON DELETE CASCADE,
  voted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (poll_option_id, user_id)
);

-- ─── Community events & RSVPs ─────────────────────────────────────────────────

CREATE TABLE community_events (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id    UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  title      VARCHAR(200) NOT NULL,
  location   VARCHAR(300),
  starts_at  TIMESTAMPTZ  NOT NULL,
  ends_at    TIMESTAMPTZ,
  rsvp_count INTEGER      NOT NULL DEFAULT 0
);

CREATE INDEX idx_events_starts_at ON community_events (starts_at);

CREATE TABLE event_rsvps (
  event_id UUID        NOT NULL REFERENCES community_events(id) ON DELETE CASCADE,
  user_id  UUID        NOT NULL REFERENCES users(id)            ON DELETE CASCADE,
  status   VARCHAR(10) NOT NULL DEFAULT 'going'
           CHECK (status IN ('going', 'maybe', 'not_going')),
  rsvp_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (event_id, user_id)
);

-- ─── Community notifications & join requests ──────────────────────────────────

CREATE TABLE community_notifications (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
  type         VARCHAR(30) NOT NULL
               CHECK (type IN (
                   'new_post', 'pinned_post',
                   'join_request', 'join_approved', 'join_rejected',
                   'role_changed', 'new_report'
               )),
  ref_id       UUID,
  is_read      BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_user
  ON community_notifications (user_id, is_read, created_at DESC);

CREATE TABLE community_join_requests (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
  status       VARCHAR(10) NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_by  UUID REFERENCES users(id),
  reviewed_at  TIMESTAMPTZ,
  UNIQUE (community_id, user_id)
);

CREATE INDEX idx_join_requests_community
  ON community_join_requests (community_id, status);

-- ─── Community moderation, analytics, discovery ───────────────────────────────

CREATE TABLE community_reports (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id  UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_type  VARCHAR(10) NOT NULL CHECK (target_type IN ('post', 'member')),
  target_id    UUID        NOT NULL,
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  reason       VARCHAR(30) NOT NULL
               CHECK (reason IN (
                   'spam', 'harassment', 'hate_speech',
                   'misinformation', 'off_topic', 'other'
               )),
  detail       TEXT,
  status       VARCHAR(10) NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'resolved', 'dismissed')),
  resolved_by  UUID REFERENCES users(id),
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reporter_id, target_type, target_id)
);

CREATE INDEX idx_reports_community ON community_reports (community_id, status);
CREATE INDEX idx_reports_target    ON community_reports (target_type, target_id);

-- Daily snapshots per community
CREATE TABLE community_analytics (
  id             UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id   UUID    NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  snapshot_date  DATE    NOT NULL,
  member_count   INTEGER NOT NULL DEFAULT 0,
  post_count     INTEGER NOT NULL DEFAULT 0,
  new_members    INTEGER NOT NULL DEFAULT 0,
  new_posts      INTEGER NOT NULL DEFAULT 0,
  active_members INTEGER NOT NULL DEFAULT 0,
  UNIQUE (community_id, snapshot_date)
);

CREATE INDEX idx_analytics_community
  ON community_analytics (community_id, snapshot_date DESC);

-- Per-user tag weights for community recommendation
CREATE TABLE recommendation_interests (
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tag        VARCHAR(50) NOT NULL,
  weight     FLOAT       NOT NULL DEFAULT 1.0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, tag)
);

CREATE INDEX idx_rec_interests_user ON recommendation_interests (user_id, weight DESC);

CREATE TABLE community_tags (
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  tag          VARCHAR(50) NOT NULL,
  PRIMARY KEY (community_id, tag)
);

CREATE INDEX idx_community_tags_tag ON community_tags (tag);

-- Trending score cache
CREATE TABLE community_trending (
  community_id UUID  NOT NULL REFERENCES communities(id) ON DELETE CASCADE PRIMARY KEY,
  score        FLOAT NOT NULL DEFAULT 0,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_trending_score ON community_trending (score DESC);

-- Permanent bans, prevents rejoin
CREATE TABLE community_bans (
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
  banned_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  banned_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (community_id, user_id)
);

CREATE INDEX idx_bans_community ON community_bans (community_id);

-- ─── Search logs & suggestion cache ───────────────────────────────────────────

CREATE TABLE search_logs (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  query      TEXT        NOT NULL,
  mode       VARCHAR(20),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_search_logs_mode_created ON search_logs (mode, created_at DESC);

-- One row per mode, refreshed hourly
CREATE TABLE suggestion_cache (
  mode        VARCHAR(20) PRIMARY KEY,
  suggestions JSONB       NOT NULL,
  computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─── Chat ─────────────────────────────────────────────────────────────────────

CREATE TABLE conversations (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  mode       VARCHAR(20) NOT NULL CHECK (mode IN ('friend', 'colleague')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_conversations_updated ON conversations (updated_at DESC);

CREATE TABLE conversation_participants (
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_read_at    TIMESTAMPTZ,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE INDEX idx_participants_user ON conversation_participants (user_id);

CREATE TABLE messages (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       UUID        NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  content         TEXT,
  message_type    VARCHAR(10) NOT NULL DEFAULT 'text'
                  CHECK (message_type IN ('text', 'image', 'video')),
  media_url       TEXT,
  status          VARCHAR(10) NOT NULL DEFAULT 'sent'
                  CHECK (status IN ('sent', 'delivered', 'read')),
  deleted_at      TIMESTAMPTZ,               -- message recall (soft delete)
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT content_or_media CHECK (content IS NOT NULL OR media_url IS NOT NULL)
);

CREATE INDEX idx_messages_conversation ON messages (conversation_id, created_at DESC);

-- ─── user_notifications (likes, comments, connections, AI notices) ────────────

CREATE TABLE user_notifications (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type        VARCHAR(50) NOT NULL,
  post_id     UUID        REFERENCES posts(id) ON DELETE CASCADE,
  payload     JSONB       NOT NULL DEFAULT '{}',
  is_read     BOOLEAN     NOT NULL DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_notifs_user   ON user_notifications (user_id, created_at DESC);
CREATE INDEX idx_user_notifs_unread ON user_notifications (user_id) WHERE is_read = FALSE;

-- ─── user_blocks ──────────────────────────────────────────────────────────────

CREATE TABLE user_blocks (
  blocker_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  blocked_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

CREATE INDEX idx_user_blocks_blocked ON user_blocks (blocked_id);

-- ─── Stories (24h) ────────────────────────────────────────────────────────────

CREATE TABLE stories (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  image_url  TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX idx_stories_author  ON stories (author_id, created_at DESC);
CREATE INDEX idx_stories_expires ON stories (expires_at);

CREATE TABLE story_views (
  story_id  UUID        NOT NULL REFERENCES stories (id) ON DELETE CASCADE,
  viewer_id UUID        NOT NULL REFERENCES users (id)   ON DELETE CASCADE,
  viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (story_id, viewer_id)
);

-- ─── user_embedding_chunks, chunk-based semantic retrieval ───────────────────
-- Replaces the former single-vector design (users.embedding / posts.embedding).
-- One row = one embeddable unit of meaning about a user:
--   source_type 'user_profile' → normalized profile text (source_id NULL)
--   source_type 'post'         → one post           (source_id = posts.id)
-- Future source types (comment, event, composite) extend the CHECK below.

CREATE TABLE user_embedding_chunks (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_type VARCHAR(20)  NOT NULL
              CHECK (source_type IN ('user_profile', 'post')),
  source_id   UUID,                          -- NULL for user_profile chunks
  chunk_index INT          NOT NULL DEFAULT 0,
  topic       VARCHAR(100),                  -- optional category label
  content     TEXT         NOT NULL,         -- exact text that was embedded
  embedding   VECTOR(1024) NOT NULL,
  model_name  VARCHAR(50)  NOT NULL DEFAULT 'mxbai-embed-large',
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Dedupe: a plain UNIQUE would not catch duplicates when source_id IS NULL,
-- so uniqueness is enforced with two partial indexes instead.
CREATE UNIQUE INDEX ux_chunks_with_source
  ON user_embedding_chunks (user_id, source_type, source_id, chunk_index)
  WHERE source_id IS NOT NULL;
CREATE UNIQUE INDEX ux_chunks_profile
  ON user_embedding_chunks (user_id, source_type, chunk_index)
  WHERE source_id IS NULL;

CREATE INDEX idx_chunks_user ON user_embedding_chunks (user_id, source_type);
-- HNSW: approximate nearest-neighbour search on cosine distance
CREATE INDEX idx_chunks_embedding
  ON user_embedding_chunks USING hnsw (embedding vector_cosine_ops);

CREATE TRIGGER trg_chunks_updated_at
  BEFORE UPDATE ON user_embedding_chunks
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
