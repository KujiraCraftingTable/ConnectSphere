-- ─────────────────────────────────────────────────────────────────────────────
-- 064, Lock profile (per persona, Facebook-style)
--
-- A locked persona shows only its name, avatar and cover to people who
-- aren't its connections in that mode, and its posts vanish for them
-- everywhere (community posts excepted. The community decides those).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN hobby_locked BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN work_locked  BOOLEAN NOT NULL DEFAULT FALSE;
