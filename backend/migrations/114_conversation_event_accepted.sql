-- 114, A message request accepted is a chat note too
--
-- Tapping Accept on a message request records an 'accepted' note, so the
-- person who sent the request gets it as an unread chat with
-- "X accepted your message request" as its inbox preview.

ALTER TABLE conversation_events DROP CONSTRAINT IF EXISTS conversation_events_kind_check;
ALTER TABLE conversation_events
  ADD CONSTRAINT conversation_events_kind_check CHECK (kind IN ('theme', 'nickname', 'accepted'));
