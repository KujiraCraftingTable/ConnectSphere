-- Migration 001: users, user_skills, user_interests

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE users (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  username         VARCHAR(50) UNIQUE NOT NULL,
  password_hash    VARCHAR(255) NOT NULL,
  display_name     VARCHAR(100) NOT NULL,
  bio              TEXT,
  avatar_color     VARCHAR(7)  NOT NULL DEFAULT '#1877F2',
  location         VARCHAR(100),

  -- Colleague-mode fields
  job_title        VARCHAR(100),
  company          VARCHAR(100),

  -- Contact
  phone            VARCHAR(20),
  email            VARCHAR(255) UNIQUE,

  -- Mode & theme preferences
  default_mode     VARCHAR(20)  NOT NULL DEFAULT 'friend'
                   CHECK (default_mode IN ('friend', 'colleague')),
  friend_theme     VARCHAR(20)  NOT NULL DEFAULT 'blue',
  colleague_theme  VARCHAR(20)  NOT NULL DEFAULT 'blue',

  -- Denormalised counters (updated via triggers or application logic)
  follower_count   INT NOT NULL DEFAULT 0,
  following_count  INT NOT NULL DEFAULT 0,
  post_count       INT NOT NULL DEFAULT 0,

  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_username ON users (username);
CREATE INDEX idx_users_email    ON users (email);

-- ── Skills (colleague mode) ──────────────────────────────────────────────────

CREATE TABLE user_skills (
  id         SERIAL      PRIMARY KEY,
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  skill      VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, skill)
);

CREATE INDEX idx_user_skills_user ON user_skills (user_id);

-- ── Interests (friend mode) ──────────────────────────────────────────────────

CREATE TABLE user_interests (
  id         SERIAL      PRIMARY KEY,
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  interest   VARCHAR(100) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, interest)
);

CREATE INDEX idx_user_interests_user ON user_interests (user_id);

-- ── Auto-update updated_at ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
