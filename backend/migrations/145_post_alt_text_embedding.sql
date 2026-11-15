-- ─────────────────────────────────────────────────────────────────────────────
-- 145, Photo alt text joins a post's search embedding
--
-- Search only read a post's caption, title and tags. The alt text people write
-- for their photos (image_alts, 045) is text about the post too, so it now
-- joins the text a post is embedded from, and so its fingerprint.
--
-- The hash only changes for posts that have alt text, so existing posts keep
-- their fingerprint and are not embedded again.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION post_embed_source_hash(p_id UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p.status <> 'posted' THEN NULL
    WHEN COALESCE(BTRIM(p.content), '') = '' AND COALESCE(BTRIM(p.article_title), '') = '' AND t.tags = '' AND j.v = ''
         AND a.v = '' THEN NULL
    ELSE md5(concat_ws(chr(31), COALESCE(p.content, ''), COALESCE(p.article_title, ''), t.tags, j.v)
             || CASE WHEN a.v = '' THEN '' ELSE chr(31) || a.v END)
  END
  FROM posts p
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(pt.tag, chr(30) ORDER BY pt.tag), '') AS tags
    FROM post_tags pt WHERE pt.post_id = p.id
  ) t
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(concat_ws(chr(30), jp.title, COALESCE(c.name, jp.company, ''), COALESCE(jp.level, ''),
             COALESCE(jp.location, ''), COALESCE(jp.work_format, ''),
             (SELECT COALESCE(string_agg(js.skill, ',' ORDER BY js.skill), '') FROM job_skills js WHERE js.job_id = jp.id)), ''), '') AS v
    FROM job_posts jp LEFT JOIN companies c ON c.id = jp.company_id WHERE jp.post_id = p.id
  ) j
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(x.alt, chr(30) ORDER BY x.n), '') AS v
    FROM unnest(p.image_alts) WITH ORDINALITY AS x(alt, n) WHERE BTRIM(COALESCE(x.alt, '')) <> ''
  ) a
  WHERE p.id = p_id
$$;
