-- ─────────────────────────────────────────────────────────────────────────────
-- 066, What a one-time code is about
--
-- A sign-in code remembers how the person signed in (google / password), so
-- the alert sent once they enter it can say so.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE account_codes ADD COLUMN meta VARCHAR(20);
