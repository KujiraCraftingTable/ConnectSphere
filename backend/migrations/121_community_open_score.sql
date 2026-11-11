-- My communities is ordered by how often you open each one, recent opens
-- counting most: every open adds 1 to a score that halves every 14 days.
-- The decay is applied when the score is updated and again when it's read,
-- so nothing needs a background job.
ALTER TABLE community_members
  ADD COLUMN IF NOT EXISTS open_score     DOUBLE PRECISION NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_opened_at TIMESTAMPTZ;
