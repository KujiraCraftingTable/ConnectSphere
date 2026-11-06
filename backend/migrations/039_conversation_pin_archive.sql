-- ─────────────────────────────────────────────────────────────────────────────
-- 039, Pin and archive a conversation (per participant)
--
-- Both are each person's own view of their inbox: pinning keeps a chat at the
-- top of *your* list, archiving moves it out of *your* main list. A new
-- message in an archived chat brings it back (Messenger-style), so archiving
-- never makes you miss a reply.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE conversation_participants ADD COLUMN pinned_at   TIMESTAMPTZ;
ALTER TABLE conversation_participants ADD COLUMN archived_at TIMESTAMPTZ;
