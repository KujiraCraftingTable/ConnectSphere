-- ─────────────────────────────────────────────────────────────────────────────
-- 021 — User-typed hashtags + per-post AI-tag visibility toggle
--
-- post_tags.source distinguishes AI-extracted tags (postTagExtractService.js,
-- async via tagQueue) from user-typed hashtags (entered at post-creation time,
-- saved synchronously). posts.show_ai_tags controls whether a post's AI tags
-- are ever surfaced via the API (buildPostSelect's tags aggregation and the
-- findAll/countAll `tag` filter both become visibility-aware in this pass) —
-- user-typed hashtags are always visible regardless of this toggle.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE post_tags
  ADD COLUMN source VARCHAR(10) NOT NULL DEFAULT 'ai' CHECK (source IN ('ai', 'user'));

ALTER TABLE posts
  ADD COLUMN show_ai_tags BOOLEAN NOT NULL DEFAULT FALSE;

-- Grandfather existing posts as visible (tags were always shown before this
-- toggle existed) — only NEW posts default to hidden-until-opted-in going
-- forward (posts.show_ai_tags's own DEFAULT FALSE above covers new rows).
UPDATE posts SET show_ai_tags = TRUE;

-- Speeds up the suggestion endpoint's prefix ILIKE match and the existing
-- case-insensitive `tag` filter's LOWER(pt.tag) comparisons.
CREATE INDEX idx_post_tags_tag_lower ON post_tags (LOWER(tag));
