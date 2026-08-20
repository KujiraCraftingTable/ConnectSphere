-- 005_hidden_posts.sql
-- "Ẩn bài viết": mỗi dòng = một bài mà một user đã ẩn khỏi feed của họ.
-- Bài ẩn bị loại khỏi mọi danh sách (feed đề xuất, list posts, tag feed)
-- của riêng user đó, nhưng vẫn mở được trực tiếp qua PostDetail
-- (share embed, notification) để tránh gãy các đường dẫn tham chiếu.

CREATE TABLE hidden_posts (
  user_id    UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  post_id    UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, post_id)
);
