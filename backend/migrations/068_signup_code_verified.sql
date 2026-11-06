-- ─────────────────────────────────────────────────────────────────────────────
-- 068, A sign-up email is confirmed before the account exists
--
-- The code is checked on the sign-up screen; the account itself is created
-- only when onboarding finishes, so the confirmation is remembered here
-- (and kept for an hour) until then.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE signup_codes ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ;
