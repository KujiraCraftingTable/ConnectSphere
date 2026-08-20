-- 008_cover_url.sql
-- Ảnh bìa hồ sơ: NULL → client hiển thị gradient mặc định theo theme.

ALTER TABLE users
  ADD COLUMN cover_url TEXT;
