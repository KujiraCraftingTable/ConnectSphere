-- ─────────────────────────────────────────────────────────────────────────────
-- 020, Meeting proposal reminders
--
-- A meeting proposal gets a scheduled reminder: reminder_offset is the
-- creator-chosen lead-time preset (display/editing label, "1 day before"),
-- reminder_at is the precomputed absolute instant it fires. reminder_at is
-- computed CLIENT-SIDE (device-local 7am, N days before starts_at) rather
-- than derived here, since this schema tracks no per-user timezone,
-- messageService.validateMeetingProposal falls back to a UTC-anchored
-- default only when a caller doesn't send one (e.g. a pre-reminder-feature
-- client). reminder_sent_at is null until MeetingReminderJob sends the
-- reminder, it doubles as the job's dedupe guard, and is reset to NULL on
-- reschedule (see messageModel.updateMeetingProposal) so a moved meeting's
-- reminder re-arms against the new time.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE message_meeting_proposals
  ADD COLUMN reminder_offset VARCHAR(20) NOT NULL DEFAULT '1_day_before'
    CHECK (reminder_offset IN ('on_day', '1_day_before', '2_days_before', '1_week_before')),
  ADD COLUMN reminder_at TIMESTAMPTZ,
  ADD COLUMN reminder_sent_at TIMESTAMPTZ;

-- Backfill for pre-existing rows: there's no real reminder_at to backfill
-- (the app never captured one before this migration), and defaulting to
-- NOW() would make the job's `reminder_at <= NOW()` guard true immediately
-- for every existing active proposal on deploy. A reminder-spam bug.
-- Instead, backfill reminder_at to each row's own starts_at (a harmless,
-- always-valid placeholder) AND stamp reminder_sent_at = NOW() so old
-- proposals read as "already sent" and the job skips them entirely.
UPDATE message_meeting_proposals
SET reminder_at = starts_at, reminder_sent_at = NOW()
WHERE reminder_at IS NULL;

ALTER TABLE message_meeting_proposals
  ALTER COLUMN reminder_at SET NOT NULL;
