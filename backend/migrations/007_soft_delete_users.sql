-- 007_soft_delete_users.sql
-- Soft delete tài khoản: deleted_at đánh dấu user đã xoá.
-- Row users được scrub PII tại chỗ (username → deleted_xxx, display_name →
-- 'Deleted User', email/google_id/password_hash → NULL...) nên mọi JOIN
-- hiển thị tên ẩn danh tự động; posts/messages giữ nguyên.

ALTER TABLE users
  ADD COLUMN deleted_at TIMESTAMPTZ;

CREATE INDEX idx_users_deleted ON users (deleted_at) WHERE deleted_at IS NOT NULL;
