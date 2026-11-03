-- ─────────────────────────────────────────────────────────────────────────────
-- 083 — Birthday changes are limited
--
-- Age decides what an account may use (Dating is 16+, and 16–17 only meets
-- 16–17), so a birthday can't be edited at will: an account gets two changes
-- in its lifetime, counted here. Setting a missing birthday from Edit profile
-- counts too; the one given at sign-up does not. Past two, support has to make
-- the change.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS dob_changes INT NOT NULL DEFAULT 0 CHECK (dob_changes >= 0);
