-- ─────────────────────────────────────────────────────────────────────────────
-- 061, Verified email, one-time codes, and deleting a persona
--
-- An account's email is now verified with a 6-digit code (Google sign-ups
-- count as verified). Deleting a persona or the whole account needs a code
-- sent to that email. A stolen password alone can't do it.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN email_verified_at TIMESTAMPTZ,
  -- A deleted persona: its old chat messages read "Deleted User" until the
  -- persona is created again.
  ADD COLUMN hobby_deleted_at  TIMESTAMPTZ,
  ADD COLUMN work_deleted_at   TIMESTAMPTZ;

-- Emails already on file (Google accounts, the owner's own) count as verified.
UPDATE users SET email_verified_at = NOW() WHERE email IS NOT NULL AND deleted_at IS NULL;

CREATE TABLE account_codes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose    VARCHAR(20) NOT NULL
    -- change_email goes to the CURRENT address: replacing a verified email
    -- needs the owner's OK, or a stolen password could redirect the codes.
    CHECK (purpose IN ('verify_email', 'change_email', 'delete_hobby', 'delete_work', 'delete_account')),
  -- Where the code went (for verify_email, the address being verified).
  email      VARCHAR(255) NOT NULL,
  code_hash  VARCHAR(100) NOT NULL,
  attempts   INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_account_codes_user ON account_codes (user_id, purpose, created_at DESC);
