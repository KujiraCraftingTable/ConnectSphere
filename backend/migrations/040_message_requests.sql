-- ─────────────────────────────────────────────────────────────────────────────
-- 040 — Message requests ("Waiting")
--
-- A 1-on-1 chat started by someone who isn't your friend in that mode lands in
-- your Waiting list instead of your inbox, and its starter can send at most 3
-- messages until you accept. `request_from` is the starter (NULL = a normal
-- chat, including every chat that existed before this). The chat counts as
-- accepted once `request_accepted_at` is set — by tapping Accept or simply
-- replying — or as soon as the two become friends (checked at query time).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE conversations ADD COLUMN request_from UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE conversations ADD COLUMN request_accepted_at TIMESTAMPTZ;
