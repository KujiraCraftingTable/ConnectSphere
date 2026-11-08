-- A forwarded message shows a plain "Forwarded" label. Only this flag is kept:
-- nothing records the original sender, message or conversation, so the
-- receiver (and the database) cannot tell where it came from.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_forwarded BOOLEAN NOT NULL DEFAULT FALSE;
