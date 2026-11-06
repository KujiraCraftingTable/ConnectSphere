-- ─────────────────────────────────────────────────────────────────────────────
-- 081, Dating (account menu, 16+ only)
--
-- Normal search is for friends (Hobby) and colleagues (Work); looking for a
-- partner happens here instead. Like Facebook Dating, it is opt-in and kept
-- apart from the rest of the app: nobody is shown in Dating without a profile
-- they turned on, and a dating profile never appears in search, profiles or
-- feeds. One profile per account, shared by both modes.
--
-- Who may enter is decided from users.age (migration 013) on every request,
-- never stored here: under 16 or no age at all is locked out, and 16–17 only
-- ever meets 16–17 (18+ only meets 18+), whatever age range someone picks.
--
-- Each profile picks its own place on a map rather than reusing the free-text
-- users.location, so distance can be measured. Height is shown, never filtered
-- or ranked on. Search doesn't judge people by looks, and neither does this.
--
-- A like or a pass is one row per (from, to); liking someone who already liked
-- you makes a match. A match chats in the normal Hobby inbox: its conversation
-- carries dating_match_id, which the inbox uses for its Dating button.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS dating_profiles (
  user_id         UUID             PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  bio             VARCHAR(500)     NOT NULL DEFAULT '',
  interested_in   VARCHAR(10)      NOT NULL CHECK (interested_in IN ('men', 'women', 'everyone')),
  min_age         INT              NOT NULL CHECK (min_age BETWEEN 16 AND 99),
  max_age         INT              NOT NULL CHECK (max_age BETWEEN 16 AND 99),
  max_distance_km INT              CHECK (max_distance_km BETWEEN 1 AND 500),  -- NULL = any distance
  height_cm       INT              CHECK (height_cm BETWEEN 100 AND 250),
  city            VARCHAR(200)     NOT NULL,
  latitude        DOUBLE PRECISION NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude       DOUBLE PRECISION NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  is_active       BOOLEAN          NOT NULL DEFAULT TRUE,  -- "Take a break" hides you without losing the profile
  created_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
  CHECK (min_age <= max_age)
);

CREATE TABLE IF NOT EXISTS dating_photos (
  user_id   UUID     NOT NULL REFERENCES dating_profiles (user_id) ON DELETE CASCADE,
  position  SMALLINT NOT NULL CHECK (position BETWEEN 0 AND 5),
  url       TEXT     NOT NULL,
  PRIMARY KEY (user_id, position)
);

CREATE TABLE IF NOT EXISTS dating_likes (
  from_user  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  to_user    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  liked      BOOLEAN     NOT NULL,  -- FALSE = a pass
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (from_user, to_user),
  CHECK (from_user <> to_user)
);

-- "Likes you": who liked me, newest first.
CREATE INDEX IF NOT EXISTS idx_dating_likes_to ON dating_likes (to_user, created_at DESC) WHERE liked;

-- The pair is stored in a fixed order (user_a < user_b) so it can only exist once.
CREATE TABLE IF NOT EXISTS dating_matches (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a               UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  user_b               UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  conversation_id      UUID        REFERENCES conversations (id) ON DELETE SET NULL,
  -- TRUE when the match opened a new chat; FALSE when the two already had a
  -- Hobby chat. Unmatching deletes only a chat the match itself made.
  created_conversation BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_a, user_b),
  CHECK (user_a < user_b)
);

CREATE INDEX IF NOT EXISTS idx_dating_matches_b ON dating_matches (user_b);

ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS dating_match_id UUID REFERENCES dating_matches (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_dating ON conversations (dating_match_id) WHERE dating_match_id IS NOT NULL;
