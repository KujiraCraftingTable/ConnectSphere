-- ─────────────────────────────────────────────────────────────────────────────
-- 048 — English ↔ Vietnamese translations of posts and comments
--
-- Translated on the server when content is published (or edited), so the
-- app's "Show translation" only swaps in text that's already here.
--   lang            en | vi | other | none (nothing to translate)
--   translated_text the other of en/vi; NULL for other languages
--   translated_hash sha256 (hex) of the text it was made from — a mismatch
--                   means the content changed and the translation is stale
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts
  ADD COLUMN lang VARCHAR(8),
  ADD COLUMN translated_text TEXT,
  ADD COLUMN translated_hash TEXT;

ALTER TABLE comments
  ADD COLUMN lang VARCHAR(8),
  ADD COLUMN translated_text TEXT,
  ADD COLUMN translated_hash TEXT;

-- Not yet looked at: what the sweep backfills first.
CREATE INDEX idx_posts_untranslated ON posts (created_at DESC) WHERE lang IS NULL AND status = 'posted';
CREATE INDEX idx_comments_untranslated ON comments (created_at DESC) WHERE lang IS NULL AND status = 'posted';
