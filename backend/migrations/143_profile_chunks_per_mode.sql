-- ─────────────────────────────────────────────────────────────────────────────
-- 143, One profile embedding per mode
--
-- A profile chunk used to mix both personas (Hobby bio and Work bio, interests
-- and skills) in one vector, so a Work search could match someone on their
-- Hobby bio. Hobby and Work are separate datasets, so each persona now gets
-- its own chunk:
--   hobby: interests, Hobby bio, location
--   work:  skills, Work bio, job title, company, work history, location
-- A mode's chunk exists only when the person has set up that persona.
--
-- The old mixed chunks are dropped; the sweep rebuilds them per mode (the
-- out-of-date view below lists every profile until both hashes match).
-- ─────────────────────────────────────────────────────────────────────────────

DELETE FROM user_embedding_chunks WHERE source_type = 'user_profile';

ALTER TABLE user_embedding_chunks
  ADD COLUMN IF NOT EXISTS mode VARCHAR(10);

ALTER TABLE user_embedding_chunks
  DROP CONSTRAINT IF EXISTS user_embedding_chunks_mode_check;
ALTER TABLE user_embedding_chunks
  ADD CONSTRAINT user_embedding_chunks_mode_check
  CHECK ((source_type = 'user_profile' AND mode IN ('hobby', 'work'))
      OR (source_type <> 'user_profile' AND mode IS NULL));

DROP INDEX IF EXISTS ux_chunks_profile;
CREATE UNIQUE INDEX ux_chunks_profile
  ON user_embedding_chunks (user_id, source_type, mode, chunk_index)
  WHERE source_id IS NULL;

DROP VIEW IF EXISTS embedding_out_of_date;
DROP FUNCTION IF EXISTS profile_embed_source_hash(UUID);

-- Fingerprint of the text one persona's profile chunk is built from. NULL =
-- nothing to embed (deleted, persona not set up, or every field empty).
CREATE OR REPLACE FUNCTION profile_embed_source_hash(u_id UUID, p_mode TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN u.deleted_at IS NOT NULL THEN NULL
    WHEN p_mode = 'hobby' THEN
      CASE
        WHEN u.hobby_display_name IS NULL THEN NULL
        WHEN COALESCE(BTRIM(u.hobby_bio), '') = '' AND u.location IS NULL AND i.v = '' THEN NULL
        ELSE md5(concat_ws(chr(31), 'hobby', COALESCE(u.hobby_bio, ''), COALESCE(u.location, ''), i.v))
      END
    WHEN p_mode = 'work' THEN
      CASE
        WHEN u.work_display_name IS NULL THEN NULL
        WHEN COALESCE(BTRIM(u.work_bio), '') = '' AND u.job_title IS NULL AND u.company IS NULL
             AND u.location IS NULL AND s.v = '' AND e.v = '' THEN NULL
        ELSE md5(concat_ws(chr(31), 'work', COALESCE(u.work_bio, ''), COALESCE(u.job_title, ''),
               COALESCE(u.company, ''), COALESCE(u.location, ''), s.v, e.v))
      END
  END
  FROM users u
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(ui.interest, chr(30) ORDER BY ui.interest), '') AS v
    FROM user_interests ui WHERE ui.user_id = u.id
  ) i
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(us.skill, chr(30) ORDER BY us.skill), '') AS v
    FROM user_skills us WHERE us.user_id = u.id
  ) s
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(we.title || ' @ ' || we.company_name, chr(30) ORDER BY we.start_month, we.id), '') AS v
    FROM work_experiences we WHERE we.user_id = u.id
  ) e
  WHERE u.id = u_id
$$;

-- Everything whose embedding is missing or built from older text. A profile's
-- source_id is the user's id; it is out of date while either persona's chunk is.
CREATE VIEW embedding_out_of_date AS
  SELECT 'post'::text AS source_type, p.id AS source_id
  FROM posts p
  CROSS JOIN LATERAL (SELECT post_embed_source_hash(p.id) AS h) x
  WHERE p.status = 'posted' AND x.h IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c
                    WHERE c.source_type = 'post' AND c.source_id = p.id AND c.source_hash = x.h)
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
