-- ─────────────────────────────────────────────────────────────────────────────
-- 011 — Reply-to-message + message reactions (minimal, bounded scope)
--
-- Adds two chat primitives that had no support at any layer:
--   1. messages.reply_to_message_id — quote a single earlier message when
--      composing a new one (self-referencing FK; SET NULL if the original
--      is ever hard-deleted, though today messages are only soft-deleted).
--   2. message_reactions — one reaction per user per message, fixed emoji
--      set. Re-tapping the same emoji removes it (handled in application
--      code via the UNIQUE constraint below); tapping a different emoji
--      replaces it (upsert).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages
  ADD COLUMN reply_to_message_id UUID REFERENCES messages(id) ON DELETE SET NULL;

CREATE INDEX idx_messages_reply_to ON messages (reply_to_message_id)
  WHERE reply_to_message_id IS NOT NULL;

CREATE TABLE message_reactions (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  emoji      VARCHAR(8)  NOT NULL CHECK (emoji IN ('❤️', '👍', '😂', '😮', '😢', '🔥')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- At most one reaction per user per message (toggle/replace, not multi-react)
  UNIQUE (message_id, user_id)
);

CREATE INDEX idx_message_reactions_message ON message_reactions (message_id);
