-- ─────────────────────────────────────────────────────────────────────────────
-- 018 — Message receipts (per-participant delivered/read tracking)
--
-- Replaces messages.status (a single sent/delivered/read enum) with a side
-- table, same reasoning as message_reactions (011): a receipt is written by a
-- different actor at a different time than the message row, and a side table
-- lets `INSERT ... ON CONFLICT DO NOTHING` give idempotent, upgrade-only
-- semantics without locking `messages`. Also required for groups — a single
-- column can't represent "read by 3 of 5"; a per-user row can.
--
-- Backfill: every message currently 'delivered' or 'read' gets a 'delivered'
-- receipt for every OTHER participant in its conversation; 'read' additionally
-- gets a 'read' receipt. This is a lossy approximation of what the old single
-- column meant (it never had per-user granularity in 1:1 either — 'read' meant
-- "the other person read it", nothing finer) — that's exactly why this backfill
-- is safe and sufficient, not a data-loss concern.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE message_receipts (
  message_id UUID        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  kind       VARCHAR(10) NOT NULL CHECK (kind IN ('delivered', 'read')),
  at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (message_id, user_id, kind)
);

CREATE INDEX idx_message_receipts_message ON message_receipts (message_id);

INSERT INTO message_receipts (message_id, user_id, kind, at)
SELECT m.id, cp.user_id, 'delivered', m.created_at
FROM messages m
JOIN conversation_participants cp ON cp.conversation_id = m.conversation_id AND cp.user_id != m.sender_id
WHERE m.status IN ('delivered', 'read');

INSERT INTO message_receipts (message_id, user_id, kind, at)
SELECT m.id, cp.user_id, 'read', m.created_at
FROM messages m
JOIN conversation_participants cp ON cp.conversation_id = m.conversation_id AND cp.user_id != m.sender_id
WHERE m.status = 'read';

ALTER TABLE messages DROP CONSTRAINT messages_status_check;
ALTER TABLE messages DROP COLUMN status;
