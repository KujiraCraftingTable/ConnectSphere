-- Markdown in bios and community descriptions (see 098 for posts/comments).
-- Existing text stays 'plain'. A bio is stored per persona, so the format is too.
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS bio_format       TEXT NOT NULL DEFAULT 'plain' CHECK (bio_format IN ('plain', 'markdown')),
  ADD COLUMN IF NOT EXISTS hobby_bio_format TEXT NOT NULL DEFAULT 'plain' CHECK (hobby_bio_format IN ('plain', 'markdown')),
  ADD COLUMN IF NOT EXISTS work_bio_format  TEXT NOT NULL DEFAULT 'plain' CHECK (work_bio_format IN ('plain', 'markdown'));
ALTER TABLE communities
  ADD COLUMN IF NOT EXISTS description_format TEXT NOT NULL DEFAULT 'plain' CHECK (description_format IN ('plain', 'markdown'));
