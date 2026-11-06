-- Migration 006: add link_url to posts (link preview)
ALTER TABLE posts ADD COLUMN IF NOT EXISTS link_url VARCHAR(2000);
