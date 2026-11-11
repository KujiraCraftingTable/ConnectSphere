-- 124, Two notes on a moderation decision
--
-- `decision_note` was shown to the people who reported the item, though the
-- admin form called it a note "for the record". It is now staff-only, and
-- what reporters may read is written separately.
ALTER TABLE moderation_cases ADD COLUMN IF NOT EXISTS reporter_message TEXT;
