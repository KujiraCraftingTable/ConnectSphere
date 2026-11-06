-- ─────────────────────────────────────────────────────────────────────────────
-- 054, Sharing a post into a chat
--
-- A 'post' message points at the shared post; the sender's optional note is
-- its content. The post's own privacy still decides who can see it, so the
-- message stores only the id. Each member's app loads the post as itself.
-- If the post is deleted the link is cleared and the card shows the post as
-- unavailable, so a post message may end up with neither content nor media.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice', 'album', 'poll', 'post'));

ALTER TABLE messages ADD COLUMN shared_post_id UUID REFERENCES posts(id) ON DELETE SET NULL;

ALTER TABLE messages DROP CONSTRAINT content_or_media;
ALTER TABLE messages ADD CONSTRAINT content_or_media
  CHECK (content IS NOT NULL OR media_url IS NOT NULL OR message_type = 'post');
