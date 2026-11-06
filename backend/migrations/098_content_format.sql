-- Markdown in user-written text. Existing rows stay 'plain' so a stray `*` or
-- `_` in an old post never turns into formatting; only content written by an
-- app that offers Markdown is saved as 'markdown'.
ALTER TABLE posts    ADD COLUMN IF NOT EXISTS content_format TEXT NOT NULL DEFAULT 'plain'
    CHECK (content_format IN ('plain', 'markdown'));
ALTER TABLE comments ADD COLUMN IF NOT EXISTS content_format TEXT NOT NULL DEFAULT 'plain'
    CHECK (content_format IN ('plain', 'markdown'));
