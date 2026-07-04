-- Migration 014: add gender column to users

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS gender VARCHAR(10) NOT NULL DEFAULT 'other'
    CHECK (gender IN ('male', 'female', 'other'));

CREATE INDEX IF NOT EXISTS idx_users_gender ON users (gender);
