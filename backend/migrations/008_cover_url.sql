-- 008_cover_url.sql
-- Profile cover photo: NULL → client shows a default theme-based gradient.

ALTER TABLE users
  ADD COLUMN cover_url TEXT;
