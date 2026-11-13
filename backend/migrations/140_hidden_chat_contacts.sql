-- ─────────────────────────────────────────────────────────────────────────────
-- 140, Hidden contacts in Messages
--
-- Long-pressing someone in the people row at the top of Messages can hide
-- them from that row. Only the row: their chat stays in the list. Private to
-- the owner and per mode (Hobby and Work stay separate). Unhidden from
-- Settings › Privacy › Hidden contacts.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS chat_hidden_contacts (
  owner_id   UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  hidden_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode       TEXT        NOT NULL CHECK (mode IN ('hobby', 'work')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (owner_id, mode, hidden_id),
  CHECK (owner_id <> hidden_id)
);
