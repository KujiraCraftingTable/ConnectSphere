-- ─────────────────────────────────────────────────────────────────────────────
-- 014 — Chat meeting/appointment proposals
--
-- Lets a chat participant propose a meetup (title/location/time), the other
-- participant(s) respond going/maybe/not_going, and the proposer can reschedule
-- (clears prior RSVPs — a response to the old time shouldn't carry over) or
-- cancel. Mirrors community_events/event_rsvps' shape, but anchored to a
-- message instead of a post since this lives inside a chat conversation.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting'));

CREATE TABLE message_meeting_proposals (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id  UUID         NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  title       VARCHAR(200) NOT NULL,
  location    VARCHAR(300),
  starts_at   TIMESTAMPTZ  NOT NULL,
  ends_at     TIMESTAMPTZ,
  status      VARCHAR(10)  NOT NULL DEFAULT 'active'
              CHECK (status IN ('active', 'cancelled')),
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE message_meeting_rsvps (
  proposal_id  UUID        NOT NULL REFERENCES message_meeting_proposals(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status       VARCHAR(10) NOT NULL DEFAULT 'going'
               CHECK (status IN ('going', 'maybe', 'not_going')),
  responded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (proposal_id, user_id)
);
