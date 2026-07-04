-- Migration 026: nhiều ảnh cho một bài viết
-- image_urls là mảng có thứ tự; image_url (cũ) giữ lại = ảnh đầu tiên
-- để tương thích ngược (link preview, shared post cũ, client cũ).

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS image_urls TEXT[];
