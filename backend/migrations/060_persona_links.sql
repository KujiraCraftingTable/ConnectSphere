-- ─────────────────────────────────────────────────────────────────────────────
-- 060 — Link between a person's two personas
--
-- Each persona's profile shows a "See Work profile" / "See Hobby profile"
-- button, on by default; each mode's settings can hide its own button. It's
-- a shortcut only: each persona stays visible to people in its own mode.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN hobby_links_work BOOLEAN NOT NULL DEFAULT TRUE,  -- Hobby profile shows "See Work profile"
  ADD COLUMN work_links_hobby BOOLEAN NOT NULL DEFAULT TRUE;  -- Work profile shows "See Hobby profile"
