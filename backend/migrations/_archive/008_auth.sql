-- Migration 008: Google auth + profile fields

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS google_id  TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS dob        DATE,
  ADD COLUMN IF NOT EXISTS is_setup   BOOLEAN NOT NULL DEFAULT FALSE;
-- is_setup = FALSE → user mới, cần onboarding
-- is_setup = TRUE  → đã điền đủ thông tin

CREATE INDEX IF NOT EXISTS idx_users_google ON users (google_id);
