-- ─────────────────────────────────────────────────────────────────────────────
-- 074 — Where a listing is, on the map
--
-- The seller picks the place on a map; `location` keeps its name and these
-- its coordinates (both or neither), for the map on the listing's page.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE listing_posts ADD COLUMN IF NOT EXISTS latitude  DOUBLE PRECISION;
ALTER TABLE listing_posts ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;

ALTER TABLE listing_posts DROP CONSTRAINT IF EXISTS listing_posts_coordinates_check;
ALTER TABLE listing_posts ADD CONSTRAINT listing_posts_coordinates_check CHECK (
  (latitude IS NULL AND longitude IS NULL)
  OR (latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)
);
