-- 017_group_block_acknowledgement.sql
-- Group block handling is alert-only, not enforcement (product decision):
-- if a group contains someone you've blocked (either direction), show an
-- alert once per distinct blocked-set rather than disabling messaging.
-- This table stores the last acknowledged blocked-id-set as a sorted string
-- so "did the blocked-set change since last ack" is a cheap comparison.

CREATE TABLE conversation_block_acks (
  conversation_id   UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id           UUID        NOT NULL REFERENCES users(id)        ON DELETE CASCADE,
  acked_blocked_ids TEXT        NOT NULL,
  acked_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (conversation_id, user_id)
);
