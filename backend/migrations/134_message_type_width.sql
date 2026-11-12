-- ─────────────────────────────────────────────────────────────────────────────
-- 134, Room for longer message types
--
-- messages.message_type was VARCHAR(10); 'legit_check' (migration 133, the
-- seller's legit card) is 11 characters.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages ALTER COLUMN message_type TYPE VARCHAR(20);
