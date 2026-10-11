-- ─────────────────────────────────────────────────────────────────────────────
-- 044 — People you may know
--
-- Suggestions are computed on request (friends of friends + people with a
-- similar profile embedding); nothing is precomputed. This stores only what
-- the user decided: who they waved away (per mode), and whether they want to
-- appear in other people's suggestions at all.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE suggestion_dismissals (
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode         VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, target_id, mode)
);

ALTER TABLE users ADD COLUMN show_in_suggestions BOOLEAN NOT NULL DEFAULT TRUE;
