-- ─────────────────────────────────────────────────────────────────────────────
-- 028, Stories mode-scoping
--
-- Stories had no mode column at all. One shared pool regardless of hobby vs.
-- work, unlike every other content type (posts/connections/conversations,
-- see 009_rename_mode_vocabulary.sql). The client only ever showed the
-- Stories row in Hobby mode, so backfill existing rows to 'hobby', that's
-- exactly what mode they were actually created/seen under.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE stories ADD COLUMN mode VARCHAR(20) NOT NULL DEFAULT 'hobby'
  CHECK (mode IN ('hobby', 'work'));

-- Drop the default once existing rows are backfilled. Same convention as
-- posts.mode: the application must always pass mode explicitly going forward.
ALTER TABLE stories ALTER COLUMN mode DROP DEFAULT;

CREATE INDEX idx_stories_mode ON stories (mode);
