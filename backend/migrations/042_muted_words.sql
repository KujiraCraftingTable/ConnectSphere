-- ─────────────────────────────────────────────────────────────────────────────
-- 042 — Muted words
--
-- Words or phrases a user doesn't want to see. Posts containing one (in the
-- text, title or a visible tag) drop out of their feeds and community lists;
-- matching comments come back flagged so the app can collapse them. A list
-- per mode, like everything else; `expires_at` NULL means "forever".
-- Matching folds accents and case at query time (unaccent, migration 032).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE muted_words (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode       VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  word       VARCHAR(50) NOT NULL CHECK (char_length(btrim(word)) BETWEEN 1 AND 50),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX uq_muted_words_user_mode_word ON muted_words (user_id, mode, lower(word));
