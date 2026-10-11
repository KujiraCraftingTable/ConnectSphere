-- ─────────────────────────────────────────────────────────────────────────────
-- 043 — AI tags are never shown
--
-- AI tags (post_tags.source = 'ai') only classify a post for AI search; the
-- tags people see, filter by and mute are the ones the author wrote. The
-- per-post opt-in that showed AI tags (021) is retired with it.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts DROP COLUMN IF EXISTS show_ai_tags;
