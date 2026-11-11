-- ─────────────────────────────────────────────────────────────────────────────
-- 120, Up to 6 photos per listing item (was 5, migration 117)
-- ListingStore.maxItemPhotos and the app's ListingPhotosViewModel.maxMedia match.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE listing_items DROP CONSTRAINT IF EXISTS listing_items_image_urls_check;
ALTER TABLE listing_items ADD CONSTRAINT listing_items_image_urls_check
  CHECK (cardinality(image_urls) BETWEEN 1 AND 6);
