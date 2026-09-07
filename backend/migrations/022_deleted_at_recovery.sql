-- ═══════════════════════════════════════════════════════════════════════════
-- 022_deleted_at_recovery.sql — delete-recovery infrastructure for posts and
-- comments.
--
-- Soft-delete already exists (status = 'deleted', row stays in the DB) but
-- there was no way to know WHEN something was deleted, so there was no way to
-- sort a "Recently Deleted" list by recency, and no way to drive a 30-day
-- auto-purge window. deleted_at is set alongside status = 'deleted' and
-- cleared back to NULL on restore.
--
-- Partial indexes (WHERE deleted_at IS NOT NULL) keep the index small — only
-- soft-deleted rows are ever looked up by deleted_at (list-my-deleted +
-- purge-job queries); the vast majority of rows (status = 'posted') never
-- touch this index at all.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE posts    ADD COLUMN deleted_at TIMESTAMPTZ NULL;
ALTER TABLE comments ADD COLUMN deleted_at TIMESTAMPTZ NULL;

CREATE INDEX idx_posts_deleted_at    ON posts (deleted_at)    WHERE deleted_at IS NOT NULL;
CREATE INDEX idx_comments_deleted_at ON comments (deleted_at) WHERE deleted_at IS NOT NULL;
