-- ─────────────────────────────────────────────────────────────────────────────
-- 067, Codes for an email typed at sign-up
--
-- The email is optional at sign-up; when one is given it's proven with a
-- 6-digit code before the account exists, so these aren't tied to a user.
-- One live code per address (a resend replaces it).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS signup_codes (
    email       VARCHAR(255) PRIMARY KEY,
    code_hash   TEXT        NOT NULL,
    attempts    INT         NOT NULL DEFAULT 0,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
