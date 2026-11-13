-- ─────────────────────────────────────────────────────────────────────────────
-- 141, A username can change once every six months
--
-- username_changed_at is NULL until the first change, so everyone may change
-- theirs once right away. A released name goes into username_history and is
-- never given to anyone else (usernames were never freed before either): a
-- renamed account can't be impersonated under its old @name. Only the same
-- person may take it back, after their next allowed change.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS username_changed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS username_history (
  username    VARCHAR(50) PRIMARY KEY,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  released_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_username_history_user ON username_history(user_id);
