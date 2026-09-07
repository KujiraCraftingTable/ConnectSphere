-- 007_soft_delete_users.sql
-- Soft delete for accounts: deleted_at marks a user as deleted.
-- The users row has its PII scrubbed in place (username → deleted_xxx, display_name →
-- 'Deleted User', email/google_id/password_hash → NULL...), so every JOIN
-- shows an anonymized name automatically; posts/messages are left untouched.

ALTER TABLE users
  ADD COLUMN deleted_at TIMESTAMPTZ;

CREATE INDEX idx_users_deleted ON users (deleted_at) WHERE deleted_at IS NOT NULL;
