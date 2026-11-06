-- ─────────────────────────────────────────────────────────────────────────────
-- 012, Allow reporting posts outside a community (feed posts)
--
-- community_reports.community_id was NOT NULL, so POST /posts/:id/report could
-- never succeed for a feed post (community_id IS NULL on every non-community
-- post). Feed-post reports aren't reviewable from any community's moderation
-- queue (there's no global admin panel yet), they're recorded for now so the
-- report isn't silently lost, same tradeoff already accepted for the "other"
-- reason bucket.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE community_reports ALTER COLUMN community_id DROP NOT NULL;
