-- ─────────────────────────────────────────────────────────────────────────────
-- 065 — Two-factor sign-in, and changing a verified email in two steps
--
-- With 2FA on, every sign-in (password or Google) needs a code emailed to the
-- verified address. Changing a verified email: a code to the current address
-- unlocks the change for 15 minutes, then the new address is verified.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN two_factor_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN email_change_until TIMESTAMPTZ;

ALTER TABLE account_codes DROP CONSTRAINT IF EXISTS account_codes_purpose_check;
ALTER TABLE account_codes ADD CONSTRAINT account_codes_purpose_check
  CHECK (purpose IN ('verify_email', 'change_email', 'delete_hobby', 'delete_work', 'delete_account',
                     'login', 'two_factor'));
