-- 020_rename_state_to_status.sql
-- 1. Thêm giá trị 'banned' vào ENUM post_state
-- 2. Đổi tên ENUM post_state → post_status
-- 3. Đổi tên column state → status trên bảng posts
-- 4. Thêm column status vào bảng comments

ALTER TYPE post_state ADD VALUE IF NOT EXISTS 'banned';
ALTER TYPE post_state RENAME TO post_status;

ALTER TABLE posts RENAME COLUMN state TO status;

ALTER TABLE comments
  ADD COLUMN status post_status NOT NULL DEFAULT 'posted';

CREATE INDEX idx_comments_status ON comments (status);
