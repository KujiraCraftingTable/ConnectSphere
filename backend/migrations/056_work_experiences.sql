-- ─────────────────────────────────────────────────────────────────────────────
-- 056, Work history (Work mode)
--
-- Each role someone has held: the company (a company page when there is one,
-- otherwise just its name), title, type, place, and the months it ran. An
-- open end means they still work there. Roles at the same company are
-- grouped on the profile with the total time there. The current role also
-- keeps users.job_title / company in step (done by the server), and roles
-- join the profile's embedding (hash below) so matching sees them.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE work_experiences (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  company_id      UUID REFERENCES companies(id) ON DELETE SET NULL,
  company_name    VARCHAR(100) NOT NULL,
  title           VARCHAR(100) NOT NULL,
  employment_type VARCHAR(15) NOT NULL
    CHECK (employment_type IN ('full_time', 'part_time', 'internship', 'contract', 'freelance', 'self_employed')),
  location        VARCHAR(100),
  location_type   VARCHAR(10) CHECK (location_type IN ('onsite', 'hybrid', 'remote')),
  start_month     DATE NOT NULL,
  end_month       DATE,
  description     VARCHAR(2000),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (end_month IS NULL OR end_month >= start_month)
);
CREATE INDEX idx_work_experiences_user ON work_experiences (user_id);
-- A company page's People tab: who works there now.
CREATE INDEX idx_work_experiences_company_current ON work_experiences (company_id) WHERE end_month IS NULL;

-- What ChunkService.buildProfileChunk embeds: both bios, job, company,
-- location, interests, skills, and now each role (title at company).
CREATE OR REPLACE FUNCTION profile_embed_source_hash(u_id UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN u.deleted_at IS NOT NULL THEN NULL
    WHEN COALESCE(BTRIM(u.hobby_bio), '') = '' AND COALESCE(BTRIM(u.work_bio), '') = ''
         AND u.job_title IS NULL AND u.company IS NULL AND u.location IS NULL
         AND i.v = '' AND s.v = '' AND e.v = '' THEN NULL
    ELSE md5(concat_ws(chr(31),
           COALESCE(u.hobby_bio, ''), COALESCE(u.work_bio, ''), COALESCE(u.job_title, ''),
           COALESCE(u.company, ''), COALESCE(u.location, ''), i.v, s.v, e.v))
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
