-- ─────────────────────────────────────────────────────────────────────────────
-- 147, The wards a post is about
--
-- A post carried no place, only the words in it, and a vector is poor at
-- place names: "Bình Thạnh" is not near "Lê Thánh Tôn". So "grilled meat in
-- Bình Thạnh" could not prefer posts about that area. When a post is embedded
-- the places written in it are now read as today's wards (`PlaceReader`,
-- migration 146 for the former names) and kept on the post, to be compared
-- ward against ward with the place a search names.
--
--   place_ward_ids        NULL = not read yet, '{}' = read, names no ward
--   place_province_codes  the provinces of those wards, plus any province the
--                         post names on its own ("ở Hà Nội")
--
-- Nobody is shown them. A post whose places have not been read counts as out
-- of date, so the sweep reads the existing posts and retries a failed read.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS place_ward_ids       UUID[],
  ADD COLUMN IF NOT EXISTS place_province_codes TEXT[];

CREATE INDEX IF NOT EXISTS idx_posts_place_wards
  ON posts USING gin (place_ward_ids) WHERE place_ward_ids IS NOT NULL;

CREATE OR REPLACE VIEW embedding_out_of_date AS
  SELECT 'post'::text AS source_type, p.id AS source_id
  FROM posts p
  CROSS JOIN LATERAL (SELECT post_embed_source_hash(p.id) AS h) x
  WHERE p.status = 'posted' AND x.h IS NOT NULL
    AND (p.place_ward_ids IS NULL
         OR NOT EXISTS (SELECT 1 FROM user_embedding_chunks c
                        WHERE c.source_type = 'post' AND c.source_id = p.id AND c.source_hash = x.h))
  UNION ALL
  SELECT 'user_profile'::text, u.id
  FROM users u
  WHERE u.deleted_at IS NULL
    AND EXISTS (
      SELECT 1 FROM (VALUES ('hobby'), ('work')) m(mode)
      CROSS JOIN LATERAL (SELECT profile_embed_source_hash(u.id, m.mode) AS h) x
      WHERE x.h IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c
                        WHERE c.source_type = 'user_profile' AND c.user_id = u.id
                          AND c.mode = m.mode AND c.source_hash = x.h));
