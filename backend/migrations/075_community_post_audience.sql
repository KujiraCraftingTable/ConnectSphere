-- ─────────────────────────────────────────────────────────────────────────────
-- 075, Who can see a community post
--
-- The poster picks: 'public' (anyone. It also shows outside the community)
-- or 'members' (only the community's members). A private community's posts
-- are always 'members'. NULL on posts outside communities; a community post
-- left NULL is treated as 'members'.
--
-- Existing posts keep what they had: public in a public community, members
-- only in a private one.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts ADD COLUMN IF NOT EXISTS community_audience TEXT;

ALTER TABLE posts DROP CONSTRAINT IF EXISTS posts_community_audience_check;
ALTER TABLE posts ADD CONSTRAINT posts_community_audience_check
  CHECK (community_audience IS NULL OR community_audience IN ('public', 'members'));

UPDATE posts p
SET community_audience = CASE WHEN c.privacy = 'public' THEN 'public' ELSE 'members' END
FROM communities c
WHERE c.id = p.community_id AND p.community_audience IS NULL;
