-- Migration 026: multiple images per post
-- image_urls is an ordered array; the old image_url is kept = the first image
-- for backward compatibility (link preview, old shared posts, old clients).

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS image_urls TEXT[];
