-- ─────────────────────────────────────────────────────────────────────────────
-- 071 — Sharing a community into a chat
--
-- A 'community' message points at the community; the sender's optional note
-- is its content. Like a shared post, only the id is stored and each member
-- loads the card as themselves.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice', 'album', 'poll', 'post', 'community'));

ALTER TABLE messages ADD COLUMN IF NOT EXISTS shared_community_id UUID REFERENCES communities(id) ON DELETE SET NULL;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS content_or_media;
ALTER TABLE messages ADD CONSTRAINT content_or_media
  CHECK (content IS NOT NULL OR media_url IS NOT NULL OR message_type IN ('post', 'community'));
