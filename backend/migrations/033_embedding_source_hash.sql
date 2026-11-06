-- Keep AI-search embeddings in step with the text they were built from.
--
-- `updated_at` can't say whether a post's *text* changed: every like, comment
-- and share bumps it through trg_posts_updated_at. So each chunk records a
-- fingerprint of exactly the fields it was embedded from, and the functions
-- below compute the current fingerprint. Equal → current; different → rebuild.
-- Likes, comments, counts and mode are deliberately not part of it.
--
-- Both functions return NULL when there is nothing to embed (post deleted or
-- empty, profile empty or account deleted). The chunk should then not exist.

ALTER TABLE user_embedding_chunks ADD COLUMN IF NOT EXISTS source_hash TEXT;

-- What ChunkService.buildPostChunk embeds: content, article title, tags.
CREATE OR REPLACE FUNCTION post_embed_source_hash(p_id UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p.status <> 'posted' THEN NULL
    WHEN COALESCE(BTRIM(p.content), '') = '' AND COALESCE(BTRIM(p.article_title), '') = '' AND t.tags = '' THEN NULL
    ELSE md5(concat_ws(chr(31), COALESCE(p.content, ''), COALESCE(p.article_title, ''), t.tags))
  END
  FROM posts p
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(pt.tag, chr(30) ORDER BY pt.tag), '') AS tags
    FROM post_tags pt WHERE pt.post_id = p.id
  ) t
  WHERE p.id = p_id
$$;

-- What ChunkService.buildProfileChunk embeds: both bios, job, company,
-- location, interests, skills.
CREATE OR REPLACE FUNCTION profile_embed_source_hash(u_id UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN u.deleted_at IS NOT NULL THEN NULL
    WHEN COALESCE(BTRIM(u.hobby_bio), '') = '' AND COALESCE(BTRIM(u.work_bio), '') = ''
         AND u.job_title IS NULL AND u.company IS NULL AND u.location IS NULL
         AND i.v = '' AND s.v = '' THEN NULL
    ELSE md5(concat_ws(chr(31),
           COALESCE(u.hobby_bio, ''), COALESCE(u.work_bio, ''), COALESCE(u.job_title, ''),
           COALESCE(u.company, ''), COALESCE(u.location, ''), i.v, s.v))
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
  WHERE u.id = u_id
$$;

-- Everything whose embedding is missing or built from older text. The sweep
-- and /health both read this, so they can't disagree. A profile's source_id
-- is the user's id.
CREATE OR REPLACE VIEW embedding_out_of_date AS
  SELECT 'post'::text AS source_type, p.id AS source_id
  FROM posts p
  CROSS JOIN LATERAL (SELECT post_embed_source_hash(p.id) AS h) x
  WHERE p.status = 'posted' AND x.h IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c
                    WHERE c.source_type = 'post' AND c.source_id = p.id AND c.source_hash = x.h)
  UNION ALL
  SELECT 'user_profile'::text, u.id
  FROM users u
  CROSS JOIN LATERAL (SELECT profile_embed_source_hash(u.id) AS h) x
  WHERE u.deleted_at IS NULL AND x.h IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM user_embedding_chunks c
                    WHERE c.source_type = 'user_profile' AND c.user_id = u.id AND c.source_hash = x.h);

-- When the sweep first saw each out-of-date item, so a change still not
-- embedded after 6 hours can be flagged (and built directly, bypassing Redis).
CREATE TABLE IF NOT EXISTS embedding_backlog (
  source_type   VARCHAR(20) NOT NULL CHECK (source_type IN ('user_profile', 'post')),
  source_id     UUID        NOT NULL,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (source_type, source_id)
);
