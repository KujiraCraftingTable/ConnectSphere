-- ─────────────────────────────────────────────────────────────────────────────
-- 046 — Drafts and scheduled posts (status values)
--
-- On its own because a new enum value can't be used in the transaction that
-- adds it (each migration file runs in one). 047 uses them.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TYPE post_status ADD VALUE IF NOT EXISTS 'draft';
ALTER TYPE post_status ADD VALUE IF NOT EXISTS 'scheduled';
