-- ─────────────────────────────────────────────────────────────────────────────
-- 050 — Bare upload paths inside notification payloads
--
-- 049 stripped the uploader's server address (localhost, LAN IP, *.local) off
-- the avatar and photo columns. Notification payloads keep a copy of the
-- sender's avatar link (`fromAvatarUrl`, `peerAvatarUrl`, …) that was taken
-- before that fix, so other devices still got an address they can't reach.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE user_notifications
SET payload = regexp_replace(
      payload::text,
      'https?://(?:localhost|127\.0\.0\.1|[A-Za-z0-9-]+\.local|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?::\d+)?(/uploads/)',
      '\1', 'g')::jsonb
WHERE payload::text ~ 'https?://(?:localhost|127\.0\.0\.1|[A-Za-z0-9-]+\.local|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?::\d+)?/uploads/';
