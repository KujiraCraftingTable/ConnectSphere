-- Tokens issued before this moment are no longer accepted. Set when the
-- password is reset, so a stolen 90-day token doesn't outlive the reset.
ALTER TABLE users ADD COLUMN IF NOT EXISTS sessions_valid_after TIMESTAMPTZ;
