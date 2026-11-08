-- Editing a chat message (text only, by its sender, within 15 minutes of
-- sending). The chat shows "Edited" with the time of the last edit, and a tap
-- reveals the text it replaced, so only the latest previous text is kept.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at        TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS previous_content TEXT;
