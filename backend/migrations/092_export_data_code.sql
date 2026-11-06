-- ─────────────────────────────────────────────────────────────────────────────
-- 092 — A code for "Download my data"
--
-- The data file holds everything about a person, so it needs the same proof as
-- deleting the account: a code sent to the verified email (a stolen session
-- alone isn't enough). Adds the purpose to the allowed list.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE account_codes DROP CONSTRAINT IF EXISTS account_codes_purpose_check;
ALTER TABLE account_codes ADD CONSTRAINT account_codes_purpose_check
  CHECK (purpose IN ('verify_email', 'change_email', 'delete_hobby', 'delete_work', 'delete_account',
                     'login', 'two_factor', 'export_data'));
