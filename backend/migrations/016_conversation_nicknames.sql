-- 016_conversation_nicknames.sql
-- Group-only nicknames: setter+target pair, since a group needs "the label I
-- gave this member," not the single shared column 1:1 conversations use.
--
-- 1:1 keeps its existing conversation_participants.nickname column and
-- behavior completely unchanged. This table is additive, used only when
-- conversations.is_group = true.

CREATE TABLE conversation_nicknames (
  conversation_id UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  setter_id       UUID        NOT NULL REFERENCES users(id)        ON DELETE CASCADE,
  target_id       UUID        NOT NULL REFERENCES users(id)        ON DELETE CASCADE,
  nickname        VARCHAR(50) NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (conversation_id, setter_id, target_id)
);
