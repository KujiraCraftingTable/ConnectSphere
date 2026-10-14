-- ─────────────────────────────────────────────────────────────────────────────
-- 058 — Job details for the Jobs tab and recommendations (Work mode)
--
-- A job can be posted as a company page (by its admins), and says how and at
-- what level it's done, its pay range (VND million / month) and the skills it
-- needs. Those skills drive "4 of 6 skills match"; the job's text joins the
-- post's embedding (hash below) so it can be matched to profiles.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE job_posts
  ADD COLUMN company_id  UUID REFERENCES companies(id) ON DELETE SET NULL,
  ADD COLUMN work_format VARCHAR(10) CHECK (work_format IN ('onsite', 'hybrid', 'remote')),
  ADD COLUMN level       VARCHAR(10) CHECK (level IN ('intern', 'fresher', 'junior', 'mid', 'senior', 'lead', 'manager')),
  ADD COLUMN salary_min  INT CHECK (salary_min >= 0),
  ADD COLUMN salary_max  INT CHECK (salary_max >= 0),
  ADD CONSTRAINT job_posts_salary_order CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max);
CREATE INDEX idx_job_posts_company ON job_posts (company_id);

CREATE TABLE job_skills (
  job_id UUID NOT NULL REFERENCES job_posts(id) ON DELETE CASCADE,
  skill  VARCHAR(50) NOT NULL,
  PRIMARY KEY (job_id, skill)
);

-- What ChunkService.buildPostChunk embeds: content, article title, tags —
-- and for a job its title, company, level, place and skills.
CREATE OR REPLACE FUNCTION post_embed_source_hash(p_id UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p.status <> 'posted' THEN NULL
    WHEN COALESCE(BTRIM(p.content), '') = '' AND COALESCE(BTRIM(p.article_title), '') = '' AND t.tags = '' AND j.v = '' THEN NULL
    ELSE md5(concat_ws(chr(31), COALESCE(p.content, ''), COALESCE(p.article_title, ''), t.tags, j.v))
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
  WHERE p.id = p_id
$$;
