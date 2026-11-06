-- ─────────────────────────────────────────────────────────────────────────────
-- 069, Posts waiting for a community's approval (status values)
--
-- On its own because a new enum value can't be used in the transaction that
-- adds it (each migration file runs in one). 070 uses them.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TYPE post_status ADD VALUE IF NOT EXISTS 'pending';
ALTER TYPE post_status ADD VALUE IF NOT EXISTS 'declined';
