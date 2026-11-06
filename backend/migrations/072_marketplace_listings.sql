-- ─────────────────────────────────────────────────────────────────────────────
-- 072, Marketplace listings
--
-- A listing is a community post (post_type 'listing') with its details here,
-- the way a job is (031): it shows in its community's feed and in the
-- Marketplace tab, and takes the community's mode, approval and visibility.
-- The description is the post's text and the photos its image_urls.
--
-- auto_reply: the seller's canned answer, sent once to each buyer who
-- messages about the listing (listing_auto_replies keeps that to once).
-- hide_from_friends: the seller's connections in the listing's mode don't
-- see it anywhere.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_post_type_check;
ALTER TABLE posts ADD CONSTRAINT posts_post_type_check
  CHECK (post_type IN ('text', 'poll', 'event', 'job', 'listing'));

CREATE TABLE IF NOT EXISTS listing_posts (
  id                 UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id            UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  title              VARCHAR(100) NOT NULL,
  -- Whole VND; 0 = free.
  price              BIGINT       NOT NULL CHECK (price >= 0),
  condition          VARCHAR(20)  NOT NULL CHECK (condition IN ('new', 'like_new', 'good', 'fair')),
  location           VARCHAR(150),
  auto_reply         VARCHAR(500),
  hide_from_friends  BOOLEAN      NOT NULL DEFAULT FALSE,
  status             VARCHAR(10)  NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'sold')),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_listing_posts_post ON listing_posts (post_id);
CREATE INDEX IF NOT EXISTS idx_listing_posts_status ON listing_posts (status, created_at DESC);

CREATE TABLE IF NOT EXISTS listing_auto_replies (
  listing_id  UUID        NOT NULL REFERENCES listing_posts(id) ON DELETE CASCADE,
  buyer_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (listing_id, buyer_id)
);

-- An automatic message is the seller's words but not the seller's reply: it
-- doesn't accept a stranger's message request on their behalf.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_auto_reply BOOLEAN NOT NULL DEFAULT FALSE;
