-- Edit history for posts and comments. Each edit that changes the text or the
-- media saves the version it replaces; edited_at marks an item as edited, so
-- the app offers "View edit history" only when there is something to show.
-- Edits made before this migration left no trace, so those items have none.
ALTER TABLE posts    ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;
ALTER TABLE comments ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS post_revisions (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id        UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  content        TEXT,
  content_format TEXT,
  image_urls     TEXT[],
  image_alts     TEXT[],
  article_title  TEXT,
  link_url       TEXT,
  -- When this version was replaced.
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_post_revisions_post ON post_revisions (post_id, created_at DESC);

CREATE TABLE IF NOT EXISTS comment_revisions (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id     UUID        NOT NULL REFERENCES comments (id) ON DELETE CASCADE,
  content        TEXT,
  content_format TEXT,
  image_url      TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_comment_revisions_comment ON comment_revisions (comment_id, created_at DESC);
