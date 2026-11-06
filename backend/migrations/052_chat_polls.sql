-- ─────────────────────────────────────────────────────────────────────────────
-- 052, Polls in group chats
--
-- A poll is a message (message_type 'poll', content = the question) with 2–6
-- options and an optional end. Like post polls, each member votes once and
-- the vote is final; unlike them, who voted for what is shown, so votes keep
-- the voter. One vote per person per poll is enforced here, not just in code.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice', 'album', 'poll'));

CREATE TABLE chat_polls (
  message_id UUID PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  ends_at    TIMESTAMPTZ
);

CREATE TABLE chat_poll_options (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES chat_polls(message_id) ON DELETE CASCADE,
  text       VARCHAR(80) NOT NULL,
  position   SMALLINT NOT NULL,
  vote_count INT NOT NULL DEFAULT 0,
  UNIQUE (message_id, position)
);

CREATE TABLE chat_poll_votes (
  message_id UUID NOT NULL REFERENCES chat_polls(message_id) ON DELETE CASCADE,
  option_id  UUID NOT NULL REFERENCES chat_poll_options(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  voted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);
CREATE INDEX idx_chat_poll_votes_option ON chat_poll_votes (option_id, voted_at);
