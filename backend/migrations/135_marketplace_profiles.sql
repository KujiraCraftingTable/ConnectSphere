-- ─────────────────────────────────────────────────────────────────────────────
-- 135, Marketplace seller profile and seller follows
--
-- Many people keep selling apart from their normal life, so a seller gets a
-- marketplace-only identity (name, avatar, cover, bio) shown on their listing
-- posts and seller page. Each empty field falls back to the normal persona.
-- Following a seller is separate from `follows` (035) so it never touches
-- friend/follow counts or the Following tab; it notifies on each new listing
-- and brings the seller's listings into the follower's Home feed.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS seller_profiles (
  user_id       UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode          VARCHAR(10)  NOT NULL CHECK (mode IN ('hobby', 'work')),
  display_name  VARCHAR(50),
  avatar_url    TEXT,
  cover_url     TEXT,
  bio           VARCHAR(300),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, mode)
);

CREATE TABLE IF NOT EXISTS seller_follows (
  follower_id  UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  seller_id    UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode         VARCHAR(10)  NOT NULL CHECK (mode IN ('hobby', 'work')),
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  PRIMARY KEY (follower_id, seller_id, mode),
  CHECK (follower_id <> seller_id)
);
CREATE INDEX IF NOT EXISTS idx_seller_follows_seller ON seller_follows (seller_id, mode);
