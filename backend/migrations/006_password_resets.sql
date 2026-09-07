-- 006_password_resets.sql
-- Password reset OTP (the "forgot password" flow):
-- each row = a 6-digit code issued to a user, stored as a bcrypt hash,
-- expires after 10 minutes, single-use (used_at marks it as used/invalidated).

CREATE TABLE password_resets (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  otp_hash   VARCHAR(255) NOT NULL,
  expires_at TIMESTAMPTZ  NOT NULL,
  used_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_password_resets_user ON password_resets (user_id, created_at DESC);
