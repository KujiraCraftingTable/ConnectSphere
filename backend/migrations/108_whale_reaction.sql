-- The whale is now the only reaction the app sends (double-tap a message).
-- Old emoji stay allowed so existing rows remain valid.
ALTER TABLE message_reactions DROP CONSTRAINT IF EXISTS message_reactions_emoji_check;
ALTER TABLE message_reactions ADD CONSTRAINT message_reactions_emoji_check
  CHECK (emoji IN ('🐳', '❤️', '👍', '😂', '😮', '😢', '🔥'));
