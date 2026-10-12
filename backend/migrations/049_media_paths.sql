-- ─────────────────────────────────────────────────────────────────────────────
-- 049 — Upload links stored as bare paths
--
-- The app used to save its own uploads with the server address the uploading
-- device used in front (http://localhost:3000/uploads/x.jpg from the
-- simulator, a LAN IP or *.local name from a phone). Other devices can't reach
-- that address, so they saw blank photos. From now on the server stores
-- /uploads/x.jpg and each client adds its own server address; this rewrites
-- the links already saved. Only dev/LAN hosts are stripped — a link to an
-- outside site keeps its host.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE FUNCTION media_path_049(u TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(u,
    '^https?://(?:localhost|127\.0\.0\.1|[A-Za-z0-9-]+\.local|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?::\d+)?(/uploads/[^?#]*)(?:[?#].*)?$',
    '\1')
$$;

UPDATE users SET avatar_url = media_path_049(avatar_url) WHERE avatar_url <> media_path_049(avatar_url);
UPDATE users SET cover_url = media_path_049(cover_url) WHERE cover_url <> media_path_049(cover_url);
UPDATE users SET hobby_avatar_url = media_path_049(hobby_avatar_url) WHERE hobby_avatar_url <> media_path_049(hobby_avatar_url);
UPDATE users SET hobby_cover_url = media_path_049(hobby_cover_url) WHERE hobby_cover_url <> media_path_049(hobby_cover_url);
UPDATE users SET work_avatar_url = media_path_049(work_avatar_url) WHERE work_avatar_url <> media_path_049(work_avatar_url);
UPDATE users SET work_cover_url = media_path_049(work_cover_url) WHERE work_cover_url <> media_path_049(work_cover_url);
UPDATE communities SET avatar_url = media_path_049(avatar_url) WHERE avatar_url <> media_path_049(avatar_url);
UPDATE conversations SET avatar_url = media_path_049(avatar_url) WHERE avatar_url <> media_path_049(avatar_url);
UPDATE stories SET image_url = media_path_049(image_url) WHERE image_url <> media_path_049(image_url);
UPDATE messages SET media_url = media_path_049(media_url) WHERE media_url <> media_path_049(media_url);

UPDATE posts
SET image_urls = ARRAY(SELECT media_path_049(u) FROM unnest(image_urls) WITH ORDINALITY AS t(u, i) ORDER BY i)
WHERE EXISTS (SELECT 1 FROM unnest(image_urls) u WHERE u <> media_path_049(u));

DROP FUNCTION media_path_049(TEXT);
