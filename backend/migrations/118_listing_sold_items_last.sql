-- ─────────────────────────────────────────────────────────────────────────────
-- 118, Sold items' photos go last
--
-- A listing of several items shows one cover per item; when the first cover
-- says "SOLD", buyers take the whole listing as sold. ListingStore.syncSummary
-- now puts sold items' covers after the rest (and the app lists the items in
-- that order); this re-sorts the covers of listings saved before that.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE posts p SET
  image_urls = s.covers,
  image_alts = CASE WHEN array_to_string(s.alts, '') = '' THEN NULL ELSE s.alts END
FROM (
  SELECT l.post_id,
         array_agg(i.image_urls[1] ORDER BY (i.status = 'sold'), i.position) AS covers,
         array_agg(COALESCE(i.image_alts[1], '') ORDER BY (i.status = 'sold'), i.position) AS alts
  FROM listing_posts l JOIN listing_items i ON i.listing_id = l.id
  GROUP BY l.post_id
  HAVING COUNT(*) > 1
) s
WHERE p.id = s.post_id;
