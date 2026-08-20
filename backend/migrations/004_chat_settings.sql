-- 004_chat_settings.sql
-- Per-conversation chat settings: shared nickname & theme, per-user mute & clear.

-- Shared chat theme for the whole conversation (both participants see the same).
-- NULL → client falls back to its default palette.
ALTER TABLE conversations
  ADD COLUMN theme VARCHAR(20);

-- Per-participant fields on conversation_participants (one row = one user in a convo):
--   nickname    : label FOR this user in this conversation, set by the OTHER person,
--                 visible to BOTH (NULL → use real display_name).
--   muted_until : this user's own mute setting —
--                   NULL       → not muted (default),
--                   future ts  → muted until that moment,
--                   'infinity' → muted until manually turned back on.
--   cleared_at  : this user's "delete on my side" marker; only messages with
--                 created_at > cleared_at are shown to this user (NULL → show all).
ALTER TABLE conversation_participants
  ADD COLUMN nickname    VARCHAR(50),
  ADD COLUMN muted_until TIMESTAMPTZ,
  ADD COLUMN cleared_at  TIMESTAMPTZ;
