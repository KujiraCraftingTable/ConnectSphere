-- 113, Chat event notes
--
-- Shared chat settings changed by someone in the chat ("Kujira changed the
-- theme to Amber", "You set Kujira's nickname to Bro") show as centered notes
-- in the timeline. They are kept apart from messages so they never count as
-- unread, appear as a last-message preview, or use up a message request.

CREATE TABLE IF NOT EXISTS conversation_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  actor_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind            VARCHAR(20) NOT NULL CHECK (kind IN ('theme', 'nickname')),
  -- 'theme': the new theme id, null for the default theme.
  theme           VARCHAR(20),
  -- 'nickname': whose nickname changed, and to what (null = cleared).
  target_id       UUID REFERENCES users(id) ON DELETE CASCADE,
  nickname        VARCHAR(50),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS conversation_events_conv_time
  ON conversation_events (conversation_id, created_at);
