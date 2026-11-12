-- ─────────────────────────────────────────────────────────────────────────────
-- 133, Check legit: a seller's review post in the Marketplace
--
-- Every seller gets one 'legit' post per mode (Hobby only for now). It never
-- shows on the profile or in feeds, only on top of their Marketplace seller
-- page. Buyers can't comment on it freely: the seller sends a buyer a legit
-- card in chat (item name + optional photo, no price), valid 3 days, and the
-- buyer uses it once to leave 0–5 stars and a comment. Strangers can't tank a
-- seller, and the seller can't delete a review (only report it).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_post_type_check;
ALTER TABLE posts ADD CONSTRAINT posts_post_type_check
  CHECK (post_type IN ('text', 'poll', 'event', 'job', 'listing', 'legit'));

CREATE UNIQUE INDEX IF NOT EXISTS uniq_legit_post_per_mode
  ON posts (author_id, mode) WHERE post_type = 'legit';

CREATE TABLE IF NOT EXISTS legit_invites (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id       UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  buyer_id        UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode            VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  listing_id      UUID        REFERENCES listing_posts (id) ON DELETE SET NULL,
  item_title      VARCHAR(100) NOT NULL,
  item_image_url  TEXT,
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '3 days',
  reviewed_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (seller_id <> buyer_id)
);
CREATE INDEX IF NOT EXISTS idx_legit_invites_seller ON legit_invites (seller_id, created_at DESC);

CREATE TABLE IF NOT EXISTS legit_reviews (
  invite_id   UUID        PRIMARY KEY REFERENCES legit_invites (id) ON DELETE CASCADE,
  post_id     UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  buyer_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  rating      SMALLINT    NOT NULL CHECK (rating BETWEEN 0 AND 5),
  comment_id  UUID        NOT NULL UNIQUE REFERENCES comments (id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_legit_reviews_post ON legit_reviews (post_id);

-- The card in chat: a 'legit_check' message points at its invite.
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice', 'album', 'poll', 'post', 'community', 'legit_check'));

ALTER TABLE messages ADD COLUMN IF NOT EXISTS legit_invite_id UUID REFERENCES legit_invites (id) ON DELETE SET NULL;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS content_or_media;
ALTER TABLE messages ADD CONSTRAINT content_or_media
  CHECK (content IS NOT NULL OR media_url IS NOT NULL OR message_type IN ('post', 'community', 'legit_check'));
