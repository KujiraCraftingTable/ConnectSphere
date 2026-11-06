-- ─────────────────────────────────────────────────────────────────────────────
-- 047, Drafts and scheduled posts
--
-- A post is a draft → (scheduled) → posted row in `posts`. Only 'posted' rows
-- ever reach feeds, profiles or search (every listing filters on it), so a
-- draft is private by construction. `publish_at` is when a scheduled post
-- goes out; on publish `created_at` becomes that moment, so it sorts as new.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts ADD COLUMN publish_at TIMESTAMPTZ;

CREATE INDEX idx_posts_scheduled_due ON posts (publish_at) WHERE status = 'scheduled';
CREATE INDEX idx_posts_unpublished_author ON posts (author_id) WHERE status IN ('draft', 'scheduled');
