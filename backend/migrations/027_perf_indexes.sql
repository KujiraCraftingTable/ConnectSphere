-- 027_perf_indexes.sql
-- Indexes for hot query paths that were doing sequential scans.
-- migrate.js wraps each file in BEGIN/COMMIT, so no CONCURRENTLY here (fine at
-- this DB's size; add CONCURRENTLY manually in a real prod cutover).

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- feedModel.buildTasteVector: "FROM post_likes WHERE user_id = $1 ORDER BY
-- created_at DESC", the PK is (post_id, user_id), so this had no usable index.
CREATE INDEX IF NOT EXISTS idx_post_likes_user
  ON post_likes (user_id, created_at DESC);

-- GET /api/posts/comments/deleted and author-scoped comment lookups.
CREATE INDEX IF NOT EXISTS idx_comments_author_status
  ON comments (author_id, status);

-- User search: every `username/display_name/location ILIKE '%term%'` was a seq
-- scan. Trigram GIN indexes make the substring match index-assisted.
CREATE INDEX IF NOT EXISTS idx_users_username_trgm
  ON users USING gin (username gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_display_name_trgm
  ON users USING gin (display_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_location_trgm
  ON users USING gin (location gin_trgm_ops);

-- birthdayJob: scans users on EXTRACT(MONTH/DAY FROM dob) daily.
CREATE INDEX IF NOT EXISTS idx_users_dob_monthday
  ON users ((EXTRACT(MONTH FROM dob)::int), (EXTRACT(DAY FROM dob)::int))
  WHERE dob IS NOT NULL;

-- meetingReminderJob: sweeps every 5 minutes for due, unsent reminders.
CREATE INDEX IF NOT EXISTS idx_meeting_proposals_reminder_due
  ON message_meeting_proposals (reminder_at)
  WHERE status = 'active' AND reminder_sent_at IS NULL;
