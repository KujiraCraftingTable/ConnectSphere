-- The official account bans a profile straight from it (no report needed).
-- That ban still goes through a case, so the person gets the usual notice and
-- can appeal; the case records that the admin opened it.
ALTER TABLE moderation_cases DROP CONSTRAINT IF EXISTS moderation_cases_source_check;
ALTER TABLE moderation_cases ADD CONSTRAINT moderation_cases_source_check
  CHECK (source IN ('report', 'auto', 'admin'));
