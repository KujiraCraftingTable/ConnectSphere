-- ─────────────────────────────────────────────────────────────────────────────
-- 085, Indexes for the feed and the embedding sweep
--
-- `user_embedding_chunks` was only indexed by `user_id` first, but the feed
-- joins a post to its chunk by `(source_type, source_id)` and the
-- `embedding_out_of_date` view checks every post the same way. A scan per
-- post, which the sweep at boot turned into seconds of load on every restart.
--
-- The feed and the post sweeps filter posts by mode and status and read the
-- newest first; the single-column indexes on each made Postgres pick one and
-- filter the rest.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_chunks_source
  ON user_embedding_chunks (source_type, source_id)
  WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_posts_mode_status_created
  ON posts (mode, status, created_at DESC)
  WHERE deleted_at IS NULL;
