-- Migration 006: thêm link_url cho posts (link preview)
ALTER TABLE posts ADD COLUMN IF NOT EXISTS link_url VARCHAR(2000);
