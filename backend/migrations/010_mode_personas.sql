-- ─────────────────────────────────────────────────────────────────────────────
-- 010 — Mode personas: mỗi account có 2 "nhân cách" độc lập theo mode
--
-- Cùng account (id/username/password) nhưng danh tính hiển thị tách riêng
-- per mode: display_name, bio, avatar_url, cover_url.
--   • Quy ước "đã setup mode X" = X_display_name IS NOT NULL
--   • bio/avatar/cover optional — NULL = hiển thị mặc định (avatar chữ cái
--     đầu tên, cover/bio trống)
--   • location/gender/dob/email vẫn dùng chung (thông tin người thật)
--   • job_title/company (users) + user_skills/user_interests giữ nguyên —
--     vốn đã là dữ liệu riêng của work/hobby mode
--   • Cột gốc display_name/bio/avatar_url/cover_url giữ làm fallback cho
--     các bề mặt không gắn mode
--
-- Backfill (option A):
--   1. Persona của default_mode = data hiện tại
--   2. User có job_title/company → work persona coi như đã setup
--   3. Đối xứng: user có interests → hobby persona coi như đã setup
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

-- 1. Persona của default_mode nhận toàn bộ danh tính hiện tại
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

-- 2. Đã có dữ liệu work (job_title/company) → work persona coi như setup,
--    chỉ lấy tên; bio/avatar/cover để NULL → hiển thị mặc định
UPDATE users SET work_display_name = display_name
WHERE work_display_name IS NULL
  AND (NULLIF(TRIM(job_title), '') IS NOT NULL
    OR NULLIF(TRIM(company),  '') IS NOT NULL);

-- 3. Đối xứng cho chiều ngược: đã có interests → hobby persona coi như setup
UPDATE users SET hobby_display_name = display_name
WHERE hobby_display_name IS NULL
  AND EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id);
