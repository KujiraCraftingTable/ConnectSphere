-- ─────────────────────────────────────────────────────────────────────────────
-- 009, Rename mode vocabulary: friend → hobby, colleague → work
--
-- Renames the mode vocabulary at the root across the whole DB to match the
-- product language (the UI already shows Hobby/Work). Consists of 3 parts:
--   1. Rename theme columns:  friend_theme → hobby_theme, colleague_theme → work_theme
--   2. Update values:    'friend' → 'hobby', 'colleague' → 'work'
--      on users.default_mode + the mode column of connections/posts/conversations/
--      search_logs/suggestion_cache
--   3. Rebuild CHECK constraints with the new values
--
-- Does NOT touch posts.privacy ('public'/'friends'/'only_me'), 'friends' there
-- is a privacy level, not a mode.
-- Runs in a single transaction (the migration runner wraps BEGIN/COMMIT automatically).
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Theme columns
ALTER TABLE users RENAME COLUMN friend_theme    TO hobby_theme;
ALTER TABLE users RENAME COLUMN colleague_theme TO work_theme;

-- 2a. users.default_mode
ALTER TABLE users DROP CONSTRAINT users_default_mode_check;
ALTER TABLE users ALTER COLUMN default_mode SET DEFAULT 'hobby';
UPDATE users SET default_mode = 'hobby' WHERE default_mode = 'friend';
UPDATE users SET default_mode = 'work'  WHERE default_mode = 'colleague';
ALTER TABLE users ADD CONSTRAINT users_default_mode_check
  CHECK (default_mode IN ('hobby', 'work'));

-- 2b. connections.mode
ALTER TABLE connections DROP CONSTRAINT connections_mode_check;
UPDATE connections SET mode = 'hobby' WHERE mode = 'friend';
UPDATE connections SET mode = 'work'  WHERE mode = 'colleague';
ALTER TABLE connections ADD CONSTRAINT connections_mode_check
  CHECK (mode IN ('hobby', 'work'));

-- 2c. posts.mode
ALTER TABLE posts DROP CONSTRAINT posts_mode_check;
UPDATE posts SET mode = 'hobby' WHERE mode = 'friend';
UPDATE posts SET mode = 'work'  WHERE mode = 'colleague';
ALTER TABLE posts ADD CONSTRAINT posts_mode_check
  CHECK (mode IN ('hobby', 'work'));

-- 2d. conversations.mode
ALTER TABLE conversations DROP CONSTRAINT conversations_mode_check;
UPDATE conversations SET mode = 'hobby' WHERE mode = 'friend';
UPDATE conversations SET mode = 'work'  WHERE mode = 'colleague';
ALTER TABLE conversations ADD CONSTRAINT conversations_mode_check
  CHECK (mode IN ('hobby', 'work'));

-- 2e. search_logs.mode / suggestion_cache.mode (no CHECK, just update the data)
UPDATE search_logs      SET mode = 'hobby' WHERE mode = 'friend';
UPDATE search_logs      SET mode = 'work'  WHERE mode = 'colleague';
UPDATE suggestion_cache SET mode = 'hobby' WHERE mode = 'friend';
UPDATE suggestion_cache SET mode = 'work'  WHERE mode = 'colleague';
