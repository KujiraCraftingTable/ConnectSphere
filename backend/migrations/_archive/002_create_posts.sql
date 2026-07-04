-- Migration 002: posts, post_tags

CREATE TABLE posts (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id     UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  content       TEXT        NOT NULL,

  -- Determines layout & feed filtering on the client
  mode          VARCHAR(20) NOT NULL CHECK (mode IN ('friend', 'colleague')),

  image_url     VARCHAR(500),
  article_title VARCHAR(255),

  -- Denormalised counters
  like_count    INT NOT NULL DEFAULT 0,
  comment_count INT NOT NULL DEFAULT 0,
  share_count   INT NOT NULL DEFAULT 0,

  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_posts_author    ON posts (author_id);
CREATE INDEX idx_posts_mode      ON posts (mode);
CREATE INDEX idx_posts_created   ON posts (created_at DESC);

-- ── Tags ─────────────────────────────────────────────────────────────────────

CREATE TABLE post_tags (
  id      SERIAL      PRIMARY KEY,
  post_id UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  tag     VARCHAR(100) NOT NULL,
  UNIQUE (post_id, tag)
);

CREATE INDEX idx_post_tags_post ON post_tags (post_id);
CREATE INDEX idx_post_tags_tag  ON post_tags (tag);

-- ── Likes (prevents duplicate likes) ─────────────────────────────────────────

CREATE TABLE post_likes (
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (post_id, user_id)
);

-- ── Auto-update updated_at ────────────────────────────────────────────────────

CREATE TRIGGER trg_posts_updated_at
  BEFORE UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
