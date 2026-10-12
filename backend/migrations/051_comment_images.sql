-- ─────────────────────────────────────────────────────────────────────────────
-- 051 — A photo on a comment
--
-- One optional photo per comment, stored like every other upload as a bare
-- /uploads/… path (see 049). A comment needs text, a photo, or both; a
-- photo-only comment keeps content = '' (the column stays NOT NULL).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE comments ADD COLUMN image_url TEXT;
