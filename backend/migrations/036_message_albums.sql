-- ─────────────────────────────────────────────────────────────────────────────
-- 036, Photo albums in chat
--
-- Several photos sent together arrive as ONE message (Messenger-style album)
-- instead of one bubble per photo. `media_items` holds the album in order as
-- [{"url": "/uploads/messages/…", "type": "image"}, …], typed per item so
-- videos could join later without another migration. `media_url` keeps the
-- first photo, so the existing content_or_media check, conversation previews
-- and anything reading a single media URL keep working unchanged. An optional
-- caption lives in `content` like any text, so message search finds it.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice', 'album'));

ALTER TABLE messages ADD COLUMN media_items JSONB;

-- An album is 2-10 items; nothing else carries media_items.
ALTER TABLE messages ADD CONSTRAINT messages_album_items_check CHECK (
  (message_type = 'album'
     AND jsonb_typeof(media_items) = 'array'
     AND jsonb_array_length(media_items) BETWEEN 2 AND 10)
  OR (message_type <> 'album' AND media_items IS NULL)
);
