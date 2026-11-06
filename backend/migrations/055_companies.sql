-- ─────────────────────────────────────────────────────────────────────────────
-- 055, Company pages (Work mode)
--
-- A company's official page: who it is (about, industry, size, website, HQ),
-- who runs it (admins) and who follows it. Anyone can create one and becomes
-- its owner; it shows as Official only once the app admin verifies it
-- (`swift run App verify-company <slug>`). Work history (056) and job posts
-- (058) link to it, which is where its People and Jobs tabs come from.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE companies (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          VARCHAR(100) NOT NULL,
  slug          VARCHAR(120) NOT NULL UNIQUE,
  logo_url      TEXT,
  cover_url     TEXT,
  about         VARCHAR(2000),
  industry      VARCHAR(80),
  size          VARCHAR(10) CHECK (size IN ('1-10', '11-50', '51-200', '201-500', '501-1000', '1000+')),
  website       VARCHAR(200),
  headquarters  VARCHAR(100),
  founded_year  SMALLINT CHECK (founded_year BETWEEN 1800 AND 2100),
  is_verified   BOOLEAN NOT NULL DEFAULT FALSE,
  follower_count INT NOT NULL DEFAULT 0,
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- One page per company name, whatever the capitals.
CREATE UNIQUE INDEX idx_companies_name_lower ON companies (lower(name));

CREATE TABLE company_admins (
  company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       VARCHAR(10) NOT NULL CHECK (role IN ('owner', 'admin')),
  added_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, user_id)
);
CREATE INDEX idx_company_admins_user ON company_admins (user_id);

CREATE TABLE company_followers (
  company_id  UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  followed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, user_id)
);
CREATE INDEX idx_company_followers_user ON company_followers (user_id);
