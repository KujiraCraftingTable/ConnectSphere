-- ─────────────────────────────────────────────────────────────────────────────
-- 019, Message pins
--
-- Lets any participant pin up to 10 messages per conversation (side table, not
-- a boolean on `messages`, because chat needs multiple *simultaneous* pins,
-- unlike Communities' single-pinned-post pattern on `posts.is_pinned`). Each
-- pin optionally carries its own expires_at for auto-delete (per-pin, not a
-- conversation-wide default); a daily job (PinExpiryJob) sweeps expired
-- rows. The 10-per-conversation cap is enforced by a COUNT(*) < 10 guard on
-- the insert itself (messageModel.pinMessage), mirroring setMeetingRsvp's
-- guard-the-write-itself style rather than a separate check-then-act.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE message_pins (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  message_id      UUID        NOT NULL REFERENCES messages(id)      ON DELETE CASCADE,
  pinned_by       UUID        NOT NULL REFERENCES users(id)         ON DELETE SET NULL,
  pinned_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,
  UNIQUE (conversation_id, message_id)
);

CREATE INDEX idx_message_pins_conversation ON message_pins (conversation_id, pinned_at DESC);
CREATE INDEX idx_message_pins_expiry ON message_pins (expires_at) WHERE expires_at IS NOT NULL;
