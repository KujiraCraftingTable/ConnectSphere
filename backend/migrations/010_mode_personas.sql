-- ─────────────────────────────────────────────────────────────────────────────
-- 010 — Mode personas: each account has 2 independent "personas" per mode
--
-- Same account (id/username/password) but the display identity is split
-- per mode: display_name, bio, avatar_url, cover_url.
--   • Convention: "mode X is set up" = X_display_name IS NOT NULL
--   • bio/avatar/cover are optional — NULL = show the default (initial-letter
--     avatar, empty cover/bio)
--   • location/gender/dob/email remain shared (real-person info)
--   • job_title/company (users) + user_skills/user_interests are unchanged —
--     they were already work/hobby-mode-specific data
--   • The original display_name/bio/avatar_url/cover_url columns are kept as
--     a fallback for surfaces that aren't mode-aware
--
-- Backfill (option A):
--   1. The default_mode's persona = current data
--   2. A user with job_title/company → work persona is considered already set up
--   3. Symmetrically: a user with interests → hobby persona is considered already set up
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN hobby_display_name VARCHAR(100),
  ADD COLUMN hobby_bio          TEXT,
  ADD COLUMN hobby_avatar_url   TEXT,
  ADD COLUMN hobby_cover_url    TEXT,
  ADD COLUMN work_display_name  VARCHAR(100),
  ADD COLUMN work_bio           TEXT,
  ADD COLUMN work_avatar_url    TEXT,
  ADD COLUMN work_cover_url     TEXT;

-- 1. The default_mode's persona takes on the full current identity
UPDATE users SET
  hobby_display_name = display_name,
  hobby_bio          = bio,
  hobby_avatar_url   = avatar_url,
  hobby_cover_url    = cover_url
WHERE default_mode = 'hobby';

UPDATE users SET
  work_display_name = display_name,
  work_bio          = bio,
  work_avatar_url   = avatar_url,
  work_cover_url    = cover_url
WHERE default_mode = 'work';

-- 2. Already has work data (job_title/company) → work persona is treated as set up,
--    only pull the name; bio/avatar/cover stay NULL → default is shown
UPDATE users SET work_display_name = display_name
WHERE work_display_name IS NULL
  AND (NULLIF(TRIM(job_title), '') IS NOT NULL
    OR NULLIF(TRIM(company),  '') IS NOT NULL);

-- 3. Symmetric case for the other direction: already has interests → hobby persona is treated as set up
UPDATE users SET hobby_display_name = display_name
WHERE hobby_display_name IS NULL
  AND EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id);
