-- 019_post_state.sql
-- Thêm ENUM type post_state và column state vào bảng posts.
-- 'posted'  = bài viết đang hiển thị bình thường
-- 'deleted' = soft-delete, ẩn khỏi feed (không xóa row)

CREATE TYPE post_state AS ENUM ('posted', 'deleted');

ALTER TABLE posts
  ADD COLUMN state post_state NOT NULL DEFAULT 'posted';

-- Migrate toàn bộ bài viết hiện tại sang 'posted'
UPDATE posts SET state = 'posted';

-- Index để filter nhanh những bài chưa bị xóa
CREATE INDEX idx_posts_state ON posts (state);
