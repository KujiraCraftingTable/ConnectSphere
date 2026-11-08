-- 112, Same-day meeting reminders
--
-- Every reminder used to fire at 7am some days before the meeting, so a
-- meeting later today had no reminder still ahead and couldn't be proposed.
-- 'at_start' fires when it begins, '1_hour_before' an hour earlier.

ALTER TABLE message_meeting_proposals
  DROP CONSTRAINT IF EXISTS message_meeting_proposals_reminder_offset_check;
ALTER TABLE message_meeting_proposals
  ADD CONSTRAINT message_meeting_proposals_reminder_offset_check
    CHECK (reminder_offset IN ('at_start', '1_hour_before', 'on_day', '1_day_before', '2_days_before', '1_week_before'));
