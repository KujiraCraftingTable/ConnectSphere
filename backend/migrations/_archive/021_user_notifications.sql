-- Migration 021: user-level notifications (AI mode mismatch, etc.)

CREATE TABLE user_notifications (
  id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type         VARCHAR(50)  NOT NULL,
  post_id      UUID         REFERENCES posts(id) ON DELETE CASCADE,
  payload      JSONB        NOT NULL DEFAULT '{}',
  is_read      BOOLEAN      NOT NULL DEFAULT FALSE,
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_notifs_user   ON user_notifications (user_id, created_at DESC);
CREATE INDEX idx_user_notifs_unread ON user_notifications (user_id) WHERE is_read = FALSE;
