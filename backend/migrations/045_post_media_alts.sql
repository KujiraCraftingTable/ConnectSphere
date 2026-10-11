-- ─────────────────────────────────────────────────────────────────────────────
-- 045 — Alt text for post media
--
-- One description per entry in image_urls, same order ('' = none). Shown in
-- the photo's place while it loads or if it fails, and read by VoiceOver.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts ADD COLUMN image_alts TEXT[];
