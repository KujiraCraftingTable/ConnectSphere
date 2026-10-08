-- ─────────────────────────────────────────────────────────────────────────────
-- 041 — Group chats in spaces
--
-- A space can hold group chats as well as people. Same privacy as 038: only
-- the space's owner sees it. A group shows in a space only while the owner is
-- still in it (leaving deletes their participant row), so nothing here needs
-- cleaning up when someone leaves.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE chat_space_conversations (
  space_id        UUID        NOT NULL REFERENCES chat_spaces(id)   ON DELETE CASCADE,
  conversation_id UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  added_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (space_id, conversation_id)
);
