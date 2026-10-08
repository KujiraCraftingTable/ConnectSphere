-- ─────────────────────────────────────────────────────────────────────────────
-- 038 — Chat spaces
--
-- A space is a private label a user puts on people ("Greenwich Uni",
-- "Badminton") to organise Messages. Only its owner ever sees it. Spaces are
-- per mode like everything else (a Hobby space never shows in Work), and one
-- person can sit in several spaces.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE chat_spaces (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id   UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode       VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  name       VARCHAR(30) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 30),
  color      VARCHAR(16) NOT NULL DEFAULT 'blue',
  position   INT         NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX uq_chat_spaces_owner_name ON chat_spaces (owner_id, mode, lower(name));
CREATE INDEX idx_chat_spaces_owner ON chat_spaces (owner_id, mode, position);

CREATE TABLE chat_space_members (
  space_id UUID        NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  user_id  UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (space_id, user_id)
);
