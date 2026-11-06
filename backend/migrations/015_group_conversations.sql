-- 015_group_conversations.sql
-- Group chat foundation: conversations gain a group flag + metadata,
-- conversation_participants gains a simple owner/member role.
--
-- Exactly-one-owner is enforced at the application layer (promote/leave
-- transactions in messageModel.transferOwnership), not a DB constraint,
-- mirrors how community_members' role invariants are app-enforced too.

ALTER TABLE conversations
  ADD COLUMN is_group    BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN name        VARCHAR(100),
  ADD COLUMN avatar_url  TEXT,
  ADD COLUMN avatar_color VARCHAR(20),
  ADD COLUMN created_by  UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE conversation_participants
  ADD COLUMN role VARCHAR(10) NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member'));

CREATE INDEX idx_conversations_is_group ON conversations (is_group);
